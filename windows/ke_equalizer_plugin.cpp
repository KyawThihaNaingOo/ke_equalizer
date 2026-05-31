#include "ke_equalizer_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#include <mmsystem.h>

namespace ke_equalizer {

namespace {

constexpr int kDefaultToneBandCount = 8;
constexpr int kDefaultSampleRate = 44100;
constexpr int kBufferSampleCount = 1024;
constexpr int kBufferCount = 4;

flutter::EncodableValue StringValue(const char* value) {
  return flutter::EncodableValue(std::string(value));
}

int ClampInt(int value, int min_value, int max_value) {
  return std::max(min_value, std::min(value, max_value));
}

int ReadIntArgument(const flutter::MethodCall<flutter::EncodableValue>& call,
                    const char* key,
                    int fallback) {
  const auto* arguments = call.arguments();
  if (!arguments) {
    return fallback;
  }
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (!map) {
    return fallback;
  }

  auto iterator = map->find(StringValue(key));
  if (iterator == map->end()) {
    return fallback;
  }

  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<int>(*value);
  }
  if (const auto* value = std::get_if<double>(&iterator->second)) {
    return static_cast<int>(*value);
  }
  return fallback;
}

std::vector<double> ToneFrequencies(int band_count, int sample_rate) {
  const double min_hz = 90.0;
  const double max_hz = std::min(8000.0, sample_rate / 2.0);
  std::vector<double> frequencies;
  frequencies.reserve(band_count);
  for (int index = 0; index < band_count; ++index) {
    const double ratio =
        static_cast<double>(index) / std::max(1, band_count - 1);
    frequencies.push_back(min_hz * std::pow(max_hz / min_hz, ratio));
  }
  return frequencies;
}

double NormalizedEnergy(const int16_t* samples,
                        int sample_count,
                        int sample_rate,
                        double frequency) {
  double real = 0.0;
  double imaginary = 0.0;
  const double step = 2.0 * 3.14159265358979323846 * frequency / sample_rate;
  for (int index = 0; index < sample_count; ++index) {
    const double sample = static_cast<double>(samples[index]) / 32768.0;
    real += sample * std::cos(step * index);
    imaginary -= sample * std::sin(step * index);
  }
  const double magnitude =
      std::sqrt(real * real + imaginary * imaginary) / sample_count;
  return std::max(0.0, std::min(magnitude * 18.0, 1.0));
}

int64_t CurrentTimeMillis() {
  const auto now = std::chrono::system_clock::now();
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             now.time_since_epoch())
      .count();
}

}  // namespace

struct KeEqualizerPlugin::CaptureState {
  HWAVEIN wave_in = nullptr;
  WAVEFORMATEX format = {};
  std::vector<std::vector<int16_t>> buffers;
  std::vector<WAVEHDR> headers;
  std::vector<double> center_frequencies;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink;
  std::atomic_bool running{false};
  std::mutex sink_mutex;
};

static void CALLBACK WaveInCallback(HWAVEIN wave_in,
                                    UINT message,
                                    DWORD_PTR instance,
                                    DWORD_PTR param1,
                                    DWORD_PTR param2) {
  if (message != WIM_DATA || instance == 0) {
    return;
  }

  auto* state =
      reinterpret_cast<KeEqualizerPlugin::CaptureState*>(instance);
  auto* header = reinterpret_cast<WAVEHDR*>(param1);
  if (!state->running.load() || !header || header->dwBytesRecorded == 0) {
    return;
  }

  const auto* samples = reinterpret_cast<const int16_t*>(header->lpData);
  const int sample_count =
      static_cast<int>(header->dwBytesRecorded / sizeof(int16_t));
  if (sample_count <= 0) {
    return;
  }

  double sum_squares = 0.0;
  for (int index = 0; index < sample_count; ++index) {
    const double sample = static_cast<double>(samples[index]) / 32768.0;
    sum_squares += sample * sample;
  }
  const double rms = std::sqrt(sum_squares / sample_count);
  const double amplitude = std::max(0.0, std::min(rms * 6.0, 1.0));

  flutter::EncodableList bands;
  bands.reserve(state->center_frequencies.size());
  for (double frequency : state->center_frequencies) {
    bands.push_back(flutter::EncodableValue(NormalizedEnergy(
        samples, sample_count, state->format.nSamplesPerSec, frequency)));
  }

  flutter::EncodableMap payload{
      {StringValue("amplitude"), flutter::EncodableValue(amplitude)},
      {StringValue("bands"), flutter::EncodableValue(bands)},
      {StringValue("timestampMillis"),
       flutter::EncodableValue(CurrentTimeMillis())},
  };

  {
    std::lock_guard<std::mutex> lock(state->sink_mutex);
    if (state->event_sink) {
      state->event_sink->Success(flutter::EncodableValue(payload));
    }
  }

  if (state->running.load()) {
    waveInAddBuffer(wave_in, header, sizeof(WAVEHDR));
  }
}

// static
void KeEqualizerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "ke_equalizer",
          &flutter::StandardMethodCodec::GetInstance());
  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "ke_equalizer/tone",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<KeEqualizerPlugin>();
  auto plugin_pointer = plugin.get();

  channel->SetMethodCallHandler(
      [plugin_pointer](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [plugin_pointer](
              const flutter::EncodableValue* arguments,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            if (!plugin_pointer->capture_state_) {
              plugin_pointer->capture_state_ =
                  std::make_unique<KeEqualizerPlugin::CaptureState>();
            }
            std::lock_guard<std::mutex> lock(
                plugin_pointer->capture_state_->sink_mutex);
            plugin_pointer->capture_state_->event_sink = std::move(events);
            return nullptr;
          },
          [plugin_pointer](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            if (plugin_pointer->capture_state_) {
              std::lock_guard<std::mutex> lock(
                  plugin_pointer->capture_state_->sink_mutex);
              plugin_pointer->capture_state_->event_sink.reset();
            }
            return nullptr;
          }));

  registrar->AddPlugin(std::move(plugin));
}

KeEqualizerPlugin::KeEqualizerPlugin() {}

KeEqualizerPlugin::~KeEqualizerPlugin() { StopToneAnalysis(); }

void KeEqualizerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
  } else if (method_call.method_name().compare("getCapabilities") == 0) {
    result->Success(flutter::EncodableValue(CapabilitiesMap()));
  } else if (method_call.method_name().compare("load") == 0 ||
             method_call.method_name().compare("setBandGain") == 0 ||
             method_call.method_name().compare("setPreset") == 0) {
    result->Success(flutter::EncodableValue(EmptyStateMap()));
  } else if (method_call.method_name().compare("play") == 0 ||
             method_call.method_name().compare("pause") == 0 ||
             method_call.method_name().compare("stop") == 0 ||
             method_call.method_name().compare("stopToneAnalysis") == 0) {
    if (method_call.method_name().compare("stopToneAnalysis") == 0) {
      StopToneAnalysis();
    }
    result->Success();
  } else if (method_call.method_name().compare("startToneAnalysis") == 0) {
    StartToneAnalysis(method_call, std::move(result));
  } else if (method_call.method_name().compare("startRecording") == 0) {
    result->Error("unsupported", "Recording is not supported on Windows yet.");
  } else if (method_call.method_name().compare("stopRecording") == 0) {
    result->Success();
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableMap KeEqualizerPlugin::CapabilitiesMap() const {
  return flutter::EncodableMap{
      {StringValue("supportsPlaybackEqualizer"), flutter::EncodableValue(false)},
      {StringValue("supportsToneAnalysis"), flutter::EncodableValue(true)},
      {StringValue("supportsRecording"), flutter::EncodableValue(false)},
      {StringValue("supportsPresets"), flutter::EncodableValue(false)},
      {StringValue("platform"), StringValue("windows")},
      {StringValue("bandCount"), flutter::EncodableValue(0)},
      {StringValue("minGainDb"), flutter::EncodableValue(-15.0)},
      {StringValue("maxGainDb"), flutter::EncodableValue(15.0)},
  };
}

flutter::EncodableMap KeEqualizerPlugin::EmptyStateMap() const {
  return flutter::EncodableMap{
      {StringValue("capabilities"), flutter::EncodableValue(CapabilitiesMap())},
      {StringValue("bands"), flutter::EncodableValue(flutter::EncodableList{})},
      {StringValue("presets"), flutter::EncodableValue(flutter::EncodableList{})},
      {StringValue("isPlaying"), flutter::EncodableValue(false)},
  };
}

void KeEqualizerPlugin::StartToneAnalysis(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!capture_state_) {
    capture_state_ = std::make_unique<CaptureState>();
  }
  if (capture_state_->running) {
    result->Success();
    return;
  }

  const int band_count =
      ClampInt(ReadIntArgument(method_call, "bandCount", kDefaultToneBandCount),
               4, 16);
  const int sample_rate =
      ClampInt(ReadIntArgument(method_call, "sampleRate", kDefaultSampleRate),
               8000, 48000);

  capture_state_->format.wFormatTag = WAVE_FORMAT_PCM;
  capture_state_->format.nChannels = 1;
  capture_state_->format.nSamplesPerSec = sample_rate;
  capture_state_->format.wBitsPerSample = 16;
  capture_state_->format.nBlockAlign =
      capture_state_->format.nChannels * capture_state_->format.wBitsPerSample /
      8;
  capture_state_->format.nAvgBytesPerSec =
      capture_state_->format.nSamplesPerSec *
      capture_state_->format.nBlockAlign;
  capture_state_->format.cbSize = 0;
  capture_state_->center_frequencies = ToneFrequencies(band_count, sample_rate);

  MMRESULT open_result =
      waveInOpen(&capture_state_->wave_in, WAVE_MAPPER,
                 &capture_state_->format,
                 reinterpret_cast<DWORD_PTR>(&WaveInCallback),
                 reinterpret_cast<DWORD_PTR>(capture_state_.get()),
                 CALLBACK_FUNCTION);
  if (open_result != MMSYSERR_NOERROR) {
    result->Error("audio_record_unavailable",
                  "No compatible Windows microphone input is available.");
    return;
  }

  capture_state_->buffers.assign(
      kBufferCount, std::vector<int16_t>(kBufferSampleCount));
  capture_state_->headers.assign(kBufferCount, WAVEHDR{});
  capture_state_->running = true;

  for (int index = 0; index < kBufferCount; ++index) {
    auto& header = capture_state_->headers[index];
    header.lpData =
        reinterpret_cast<LPSTR>(capture_state_->buffers[index].data());
    header.dwBufferLength = static_cast<DWORD>(
        capture_state_->buffers[index].size() * sizeof(int16_t));

    if (waveInPrepareHeader(capture_state_->wave_in, &header,
                            sizeof(WAVEHDR)) != MMSYSERR_NOERROR ||
        waveInAddBuffer(capture_state_->wave_in, &header, sizeof(WAVEHDR)) !=
            MMSYSERR_NOERROR) {
      StopToneAnalysis();
      result->Error("audio_record_unavailable",
                    "Windows microphone buffers could not be initialized.");
      return;
    }
  }

  if (waveInStart(capture_state_->wave_in) != MMSYSERR_NOERROR) {
    StopToneAnalysis();
    result->Error("tone_start_failed",
                  "Windows microphone capture could not be started.");
    return;
  }

  result->Success();
}

void KeEqualizerPlugin::StopToneAnalysis() {
  if (!capture_state_ || !capture_state_->wave_in) {
    return;
  }

  capture_state_->running = false;
  waveInReset(capture_state_->wave_in);
  for (auto& header : capture_state_->headers) {
    if (header.dwFlags & WHDR_PREPARED) {
      waveInUnprepareHeader(capture_state_->wave_in, &header, sizeof(WAVEHDR));
    }
  }
  waveInClose(capture_state_->wave_in);
  capture_state_->wave_in = nullptr;
  capture_state_->headers.clear();
  capture_state_->buffers.clear();
}

}  // namespace ke_equalizer
