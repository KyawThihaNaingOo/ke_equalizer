#include "include/ke_equalizer/ke_equalizer_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gtk/gtk.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "ke_equalizer_plugin_private.h"

#define KE_EQUALIZER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), ke_equalizer_plugin_get_type(), \
                              KeEqualizerPlugin))

namespace {

constexpr int kBandCount = 8;
constexpr double kMinGainDb = -15.0;
constexpr double kMaxGainDb = 15.0;
constexpr double kPi = 3.14159265358979323846;

const double kCenterFrequencies[kBandCount] = {
    60.0, 170.0, 310.0, 600.0, 1000.0, 3000.0, 6000.0, 12000.0};

const char* kPresetNames[] = {
    "Flat", "Bass Boost", "Treble Boost", "Vocal", "Rock", "Electronic"};

const double kPresetGains[][kBandCount] = {
    {0, 0, 0, 0, 0, 0, 0, 0},
    {7, 5, 3, 1, 0, -1, -2, -2},
    {-2, -2, -1, 0, 1, 3, 5, 7},
    {-3, -2, 1, 4, 5, 3, 0, -2},
    {5, 3, -2, -3, 1, 3, 5, 4},
    {6, 4, 1, 0, -2, 2, 5, 6},
};

void ensure_gstreamer_initialized() {
  static gsize initialized = 0;
  if (g_once_init_enter(&initialized)) {
    gst_init(nullptr, nullptr);
    g_once_init_leave(&initialized, 1);
  }
}

double clamp_double(double value, double min_value, double max_value) {
  return std::max(min_value, std::min(value, max_value));
}

int clamp_int(int value, int min_value, int max_value) {
  return std::max(min_value, std::min(value, max_value));
}

int fl_value_lookup_int(FlValue* map, const gchar* key, int fallback) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return static_cast<int>(fl_value_get_int(value));
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    return static_cast<int>(fl_value_get_float(value));
  }
  return fallback;
}

std::vector<double> tone_frequencies(int band_count, int sample_rate) {
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

double normalized_energy(const gint16* samples,
                         int sample_count,
                         int sample_rate,
                         double frequency) {
  double real = 0.0;
  double imaginary = 0.0;
  const double step = 2.0 * kPi * frequency / sample_rate;
  for (int index = 0; index < sample_count; ++index) {
    const double sample = static_cast<double>(samples[index]) / 32768.0;
    real += sample * std::cos(step * index);
    imaginary -= sample * std::sin(step * index);
  }
  const double magnitude =
      std::sqrt(real * real + imaginary * imaginary) / sample_count;
  return clamp_double(magnitude * 18.0, 0.0, 1.0);
}

gboolean file_exists(const std::string& path) {
  struct stat info = {};
  return stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode);
}

std::string executable_directory() {
  gchar buffer[4096] = {};
  const ssize_t length = readlink("/proc/self/exe", buffer, sizeof(buffer) - 1);
  if (length <= 0) {
    return ".";
  }
  buffer[length] = '\0';
  g_autofree gchar* directory = g_path_get_dirname(buffer);
  return directory;
}

std::string resolve_asset_path(const gchar* value) {
  const std::string asset(value);
  const std::string exe_dir = executable_directory();
  std::vector<std::string> candidates = {
      asset,
      "flutter_assets/" + asset,
      "data/flutter_assets/" + asset,
      exe_dir + "/data/flutter_assets/" + asset,
      exe_dir + "/../data/flutter_assets/" + asset,
  };

  for (const auto& candidate : candidates) {
    if (file_exists(candidate)) {
      return candidate;
    }
  }
  return "";
}

FlValue* capabilities_map() {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "supportsPlaybackEqualizer",
                           fl_value_new_bool(true));
  fl_value_set_string_take(map, "supportsToneAnalysis", fl_value_new_bool(true));
  fl_value_set_string_take(map, "supportsRecording", fl_value_new_bool(false));
  fl_value_set_string_take(map, "supportsPresets", fl_value_new_bool(true));
  fl_value_set_string_take(map, "platform", fl_value_new_string("linux"));
  fl_value_set_string_take(map, "bandCount", fl_value_new_int(kBandCount));
  fl_value_set_string_take(map, "minGainDb", fl_value_new_float(kMinGainDb));
  fl_value_set_string_take(map, "maxGainDb", fl_value_new_float(kMaxGainDb));
  return map;
}

}  // namespace

struct _KeEqualizerPlugin {
  GObject parent_instance;
  FlEventChannel* event_channel;
  GstElement* playbin;
  GstElement* equalizer;
  GstElement* capture_pipeline;
  GstElement* capture_sink;
  guint bus_watch_id;
  gboolean event_listening;
  gboolean should_loop;
  gboolean is_playing;
  gint tone_sample_rate;
  gint tone_band_count;
  double band_gains[kBandCount];
  gint current_preset_index;
};

G_DEFINE_TYPE(KeEqualizerPlugin, ke_equalizer_plugin, g_object_get_type())

static void apply_equalizer_gains(KeEqualizerPlugin* self) {
  if (self->equalizer == nullptr) {
    return;
  }

  for (int index = 0; index < kBandCount; ++index) {
    g_autofree gchar* property = g_strdup_printf("band%d", index);
    g_object_set(self->equalizer, property, self->band_gains[index], nullptr);
  }
  g_object_set(self->equalizer, "band8", 0.0, "band9", 0.0, nullptr);
}

static FlValue* state_map(KeEqualizerPlugin* self) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "capabilities", capabilities_map());

  FlValue* bands = fl_value_new_list();
  for (int index = 0; index < kBandCount; ++index) {
    FlValue* band = fl_value_new_map();
    fl_value_set_string_take(band, "index", fl_value_new_int(index));
    fl_value_set_string_take(band, "centerFrequencyHz",
                             fl_value_new_float(kCenterFrequencies[index]));
    fl_value_set_string_take(band, "gainDb",
                             fl_value_new_float(self->band_gains[index]));
    fl_value_set_string_take(band, "minGainDb", fl_value_new_float(kMinGainDb));
    fl_value_set_string_take(band, "maxGainDb", fl_value_new_float(kMaxGainDb));
    fl_value_append_take(bands, band);
  }
  fl_value_set_string_take(map, "bands", bands);

  FlValue* presets = fl_value_new_list();
  for (int index = 0; index < static_cast<int>(G_N_ELEMENTS(kPresetNames));
       ++index) {
    FlValue* preset = fl_value_new_map();
    fl_value_set_string_take(preset, "index", fl_value_new_int(index));
    fl_value_set_string_take(preset, "name",
                             fl_value_new_string(kPresetNames[index]));
    fl_value_append_take(presets, preset);
  }
  fl_value_set_string_take(map, "presets", presets);
  if (self->current_preset_index >= 0) {
    fl_value_set_string_take(map, "currentPresetIndex",
                             fl_value_new_int(self->current_preset_index));
  } else {
    fl_value_set_string_take(map, "currentPresetIndex", fl_value_new_null());
  }
  fl_value_set_string_take(map, "isPlaying", fl_value_new_bool(self->is_playing));
  return map;
}

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

FlMethodResponse* get_capabilities() {
  g_autoptr(FlValue) result = capabilities_map();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static gboolean playback_bus_cb(GstBus* bus, GstMessage* message, gpointer data) {
  KeEqualizerPlugin* self = KE_EQUALIZER_PLUGIN(data);
  if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS && self->should_loop) {
    gst_element_seek_simple(self->playbin, GST_FORMAT_TIME,
                            static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                                      GST_SEEK_FLAG_KEY_UNIT),
                            0);
    gst_element_set_state(self->playbin, GST_STATE_PLAYING);
  } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
    self->is_playing = FALSE;
  }
  return G_SOURCE_CONTINUE;
}

static GstElement* create_audio_filter(KeEqualizerPlugin* self) {
  GstElement* bin = gst_bin_new("ke_equalizer_filter");
  GstElement* convert_in = gst_element_factory_make("audioconvert", nullptr);
  GstElement* equalizer =
      gst_element_factory_make("equalizer-10bands", "ke_equalizer_eq");
  GstElement* convert_out = gst_element_factory_make("audioconvert", nullptr);

  if (bin == nullptr || convert_in == nullptr || equalizer == nullptr ||
      convert_out == nullptr) {
    if (bin != nullptr) {
      gst_object_unref(bin);
    }
    return nullptr;
  }

  gst_bin_add_many(GST_BIN(bin), convert_in, equalizer, convert_out, nullptr);
  if (!gst_element_link_many(convert_in, equalizer, convert_out, nullptr)) {
    gst_object_unref(bin);
    return nullptr;
  }

  GstPad* sink_pad = gst_element_get_static_pad(convert_in, "sink");
  GstPad* src_pad = gst_element_get_static_pad(convert_out, "src");
  gst_element_add_pad(bin, gst_ghost_pad_new("sink", sink_pad));
  gst_element_add_pad(bin, gst_ghost_pad_new("src", src_pad));
  gst_object_unref(sink_pad);
  gst_object_unref(src_pad);

  self->equalizer = equalizer;
  apply_equalizer_gains(self);
  return bin;
}

static FlMethodResponse* load_audio(KeEqualizerPlugin* self,
                                    FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_source", "Audio source requires type and value.", nullptr));
  }

  FlValue* type_value = fl_value_lookup_string(args, "type");
  FlValue* source_value = fl_value_lookup_string(args, "value");
  if (type_value == nullptr || source_value == nullptr ||
      fl_value_get_type(type_value) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(source_value) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_source", "Audio source requires type and value.", nullptr));
  }

  ensure_gstreamer_initialized();
  const gchar* type = fl_value_get_string(type_value);
  const gchar* source = fl_value_get_string(source_value);

  std::string uri;
  if (strcmp(type, "asset") == 0) {
    const std::string path = resolve_asset_path(source);
    if (path.empty()) {
      g_autofree gchar* message =
          g_strdup_printf("Audio asset was not found: %s.", source);
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new("load_failed", message, nullptr));
    }
    g_autofree gchar* file_uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
    uri = file_uri == nullptr ? "" : file_uri;
  } else if (strcmp(type, "file") == 0) {
    g_autofree gchar* file_uri = g_filename_to_uri(source, nullptr, nullptr);
    uri = file_uri == nullptr ? "" : file_uri;
  } else if (strcmp(type, "url") == 0) {
    uri = source;
  } else {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unsupported_source", "Unsupported source type.", nullptr));
  }

  if (uri.empty()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "load_failed", "Audio source URI could not be created.", nullptr));
  }

  if (self->playbin != nullptr) {
    gst_element_set_state(self->playbin, GST_STATE_NULL);
    gst_object_unref(self->playbin);
    self->playbin = nullptr;
    self->equalizer = nullptr;
  }
  if (self->bus_watch_id != 0) {
    g_source_remove(self->bus_watch_id);
    self->bus_watch_id = 0;
  }

  self->playbin = gst_element_factory_make("playbin", nullptr);
  GstElement* filter = create_audio_filter(self);
  if (self->playbin == nullptr || filter == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "load_failed", "GStreamer playbin/equalizer elements are unavailable.",
        nullptr));
  }

  g_object_set(self->playbin, "uri", uri.c_str(), "audio-filter", filter,
               nullptr);
  GstBus* bus = gst_element_get_bus(self->playbin);
  self->bus_watch_id = gst_bus_add_watch(bus, playback_bus_cb, self);
  gst_object_unref(bus);
  self->should_loop = TRUE;
  self->is_playing = FALSE;

  gst_element_set_state(self->playbin, GST_STATE_PAUSED);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(state_map(self)));
}

static FlMethodResponse* set_band_gain(KeEqualizerPlugin* self,
                                       FlMethodCall* method_call) {
  if (self->playbin == nullptr || self->equalizer == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_loaded", "Load audio before changing equalizer bands.", nullptr));
  }
  FlValue* args = fl_method_call_get_args(method_call);
  const int band_index = fl_value_lookup_int(args, "bandIndex", -1);
  FlValue* gain_value = fl_value_lookup_string(args, "gainDb");
  if (band_index < 0 || band_index >= kBandCount || gain_value == nullptr ||
      (fl_value_get_type(gain_value) != FL_VALUE_TYPE_INT &&
       fl_value_get_type(gain_value) != FL_VALUE_TYPE_FLOAT)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_band", "Band index or gain is invalid.", nullptr));
  }

  const double gain = fl_value_get_type(gain_value) == FL_VALUE_TYPE_INT
                          ? fl_value_get_int(gain_value)
                          : fl_value_get_float(gain_value);
  self->band_gains[band_index] = clamp_double(gain, kMinGainDb, kMaxGainDb);
  self->current_preset_index = -1;
  apply_equalizer_gains(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(state_map(self)));
}

static FlMethodResponse* set_preset(KeEqualizerPlugin* self,
                                    FlMethodCall* method_call) {
  if (self->playbin == nullptr || self->equalizer == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_loaded", "Load audio before applying presets.", nullptr));
  }
  FlValue* args = fl_method_call_get_args(method_call);
  const int preset_index = fl_value_lookup_int(args, "presetIndex", -1);
  if (preset_index < 0 ||
      preset_index >= static_cast<int>(G_N_ELEMENTS(kPresetNames))) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_preset", "Preset index is invalid.", nullptr));
  }
  for (int index = 0; index < kBandCount; ++index) {
    self->band_gains[index] = kPresetGains[preset_index][index];
  }
  self->current_preset_index = preset_index;
  apply_equalizer_gains(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(state_map(self)));
}

struct ToneEvent {
  KeEqualizerPlugin* plugin;
  double amplitude;
  std::vector<double> bands;
  gint64 timestamp_millis;
};

static gboolean send_tone_event(gpointer data) {
  std::unique_ptr<ToneEvent> event(static_cast<ToneEvent*>(data));
  if (!event->plugin->event_listening || event->plugin->event_channel == nullptr) {
    return G_SOURCE_REMOVE;
  }

  g_autoptr(FlValue) payload = fl_value_new_map();
  fl_value_set_string_take(payload, "amplitude",
                           fl_value_new_float(event->amplitude));
  FlValue* bands = fl_value_new_list();
  for (double band : event->bands) {
    fl_value_append_take(bands, fl_value_new_float(band));
  }
  fl_value_set_string_take(payload, "bands", bands);
  fl_value_set_string_take(payload, "timestampMillis",
                           fl_value_new_int(event->timestamp_millis));
  fl_event_channel_send(event->plugin->event_channel, payload, nullptr, nullptr);
  return G_SOURCE_REMOVE;
}

static GstFlowReturn capture_sample_cb(GstAppSink* sink, gpointer data) {
  KeEqualizerPlugin* self = KE_EQUALIZER_PLUGIN(data);
  g_autoptr(GstSample) sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  if (buffer == nullptr) {
    return GST_FLOW_OK;
  }

  GstMapInfo map = {};
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    return GST_FLOW_OK;
  }

  const auto* samples = reinterpret_cast<const gint16*>(map.data);
  const int sample_count = static_cast<int>(map.size / sizeof(gint16));
  if (sample_count <= 0) {
    gst_buffer_unmap(buffer, &map);
    return GST_FLOW_OK;
  }

  double sum_squares = 0.0;
  for (int index = 0; index < sample_count; ++index) {
    const double sample_value = static_cast<double>(samples[index]) / 32768.0;
    sum_squares += sample_value * sample_value;
  }

  const double rms = std::sqrt(sum_squares / sample_count);
  auto event = std::make_unique<ToneEvent>();
  event->plugin = self;
  event->amplitude = clamp_double(rms * 6.0, 0.0, 1.0);
  event->timestamp_millis = g_get_real_time() / 1000;
  const auto frequencies =
      tone_frequencies(self->tone_band_count, self->tone_sample_rate);
  for (double frequency : frequencies) {
    event->bands.push_back(normalized_energy(
        samples, sample_count, self->tone_sample_rate, frequency));
  }

  gst_buffer_unmap(buffer, &map);
  g_main_context_invoke(nullptr, send_tone_event, event.release());
  return GST_FLOW_OK;
}

static FlMethodResponse* start_tone_analysis(KeEqualizerPlugin* self,
                                             FlMethodCall* method_call) {
  ensure_gstreamer_initialized();
  if (self->capture_pipeline != nullptr) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }

  FlValue* args = fl_method_call_get_args(method_call);
  self->tone_band_count =
      clamp_int(fl_value_lookup_int(args, "bandCount", 8), 4, 16);
  self->tone_sample_rate =
      clamp_int(fl_value_lookup_int(args, "sampleRate", 44100), 8000, 48000);

  g_autofree gchar* pipeline_description = g_strdup_printf(
      "autoaudiosrc ! audioconvert ! audioresample ! "
      "audio/x-raw,format=S16LE,channels=1,rate=%d ! "
      "appsink name=ke_equalizer_capture emit-signals=true sync=false "
      "max-buffers=2 drop=true",
      self->tone_sample_rate);
  g_autoptr(GError) error = nullptr;
  self->capture_pipeline = gst_parse_launch(pipeline_description, &error);
  if (self->capture_pipeline == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "audio_record_unavailable",
        error == nullptr ? "Linux microphone input is unavailable."
                         : error->message,
        nullptr));
  }

  self->capture_sink =
      gst_bin_get_by_name(GST_BIN(self->capture_pipeline), "ke_equalizer_capture");
  if (self->capture_sink == nullptr) {
    gst_object_unref(self->capture_pipeline);
    self->capture_pipeline = nullptr;
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "audio_record_unavailable",
        "Linux microphone capture sink could not be initialized.", nullptr));
  }

  g_signal_connect(self->capture_sink, "new-sample",
                   G_CALLBACK(capture_sample_cb), self);
  GstStateChangeReturn state = gst_element_set_state(self->capture_pipeline,
                                                     GST_STATE_PLAYING);
  if (state == GST_STATE_CHANGE_FAILURE) {
    gst_object_unref(self->capture_sink);
    self->capture_sink = nullptr;
    gst_object_unref(self->capture_pipeline);
    self->capture_pipeline = nullptr;
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "tone_start_failed", "Linux microphone capture could not be started.",
        nullptr));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void stop_tone_analysis(KeEqualizerPlugin* self) {
  if (self->capture_pipeline != nullptr) {
    gst_element_set_state(self->capture_pipeline, GST_STATE_NULL);
    gst_object_unref(self->capture_pipeline);
    self->capture_pipeline = nullptr;
  }
  if (self->capture_sink != nullptr) {
    gst_object_unref(self->capture_sink);
    self->capture_sink = nullptr;
  }
}

static void stop_playback(KeEqualizerPlugin* self, gboolean reset_position) {
  if (self->playbin == nullptr) {
    return;
  }
  gst_element_set_state(self->playbin, GST_STATE_PAUSED);
  if (reset_position) {
    gst_element_seek_simple(self->playbin, GST_FORMAT_TIME,
                            static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                                      GST_SEEK_FLAG_KEY_UNIT),
                            0);
  }
  self->is_playing = FALSE;
}

static void ke_equalizer_plugin_handle_method_call(
    KeEqualizerPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "getCapabilities") == 0) {
    response = get_capabilities();
  } else if (strcmp(method, "load") == 0) {
    response = load_audio(self, method_call);
  } else if (strcmp(method, "play") == 0) {
    if (self->playbin == nullptr) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "not_loaded", "Load audio before playback.", nullptr));
    } else {
      gst_element_set_state(self->playbin, GST_STATE_PLAYING);
      self->is_playing = TRUE;
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "pause") == 0) {
    if (self->playbin != nullptr) {
      gst_element_set_state(self->playbin, GST_STATE_PAUSED);
    }
    self->is_playing = FALSE;
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "stop") == 0) {
    stop_playback(self, TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setBandGain") == 0) {
    response = set_band_gain(self, method_call);
  } else if (strcmp(method, "setPreset") == 0) {
    response = set_preset(self, method_call);
  } else if (strcmp(method, "startToneAnalysis") == 0) {
    response = start_tone_analysis(self, method_call);
  } else if (strcmp(method, "stopToneAnalysis") == 0) {
    stop_tone_analysis(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "startRecording") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unsupported", "Recording is not supported on Linux yet.", nullptr));
  } else if (strcmp(method, "stopRecording") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static FlMethodErrorResponse* listen_cb(FlEventChannel* channel,
                                        FlValue* args,
                                        gpointer user_data) {
  KeEqualizerPlugin* self = KE_EQUALIZER_PLUGIN(user_data);
  self->event_listening = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* channel,
                                        FlValue* args,
                                        gpointer user_data) {
  KeEqualizerPlugin* self = KE_EQUALIZER_PLUGIN(user_data);
  self->event_listening = FALSE;
  return nullptr;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  KeEqualizerPlugin* plugin = KE_EQUALIZER_PLUGIN(user_data);
  ke_equalizer_plugin_handle_method_call(plugin, method_call);
}

static void ke_equalizer_plugin_dispose(GObject* object) {
  KeEqualizerPlugin* self = KE_EQUALIZER_PLUGIN(object);
  stop_tone_analysis(self);
  if (self->bus_watch_id != 0) {
    g_source_remove(self->bus_watch_id);
    self->bus_watch_id = 0;
  }
  if (self->playbin != nullptr) {
    gst_element_set_state(self->playbin, GST_STATE_NULL);
    gst_object_unref(self->playbin);
    self->playbin = nullptr;
  }
  if (self->event_channel != nullptr) {
    g_object_unref(self->event_channel);
    self->event_channel = nullptr;
  }
  G_OBJECT_CLASS(ke_equalizer_plugin_parent_class)->dispose(object);
}

static void ke_equalizer_plugin_class_init(KeEqualizerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = ke_equalizer_plugin_dispose;
}

static void ke_equalizer_plugin_init(KeEqualizerPlugin* self) {
  self->event_channel = nullptr;
  self->playbin = nullptr;
  self->equalizer = nullptr;
  self->capture_pipeline = nullptr;
  self->capture_sink = nullptr;
  self->bus_watch_id = 0;
  self->event_listening = FALSE;
  self->should_loop = FALSE;
  self->is_playing = FALSE;
  self->tone_sample_rate = 44100;
  self->tone_band_count = 8;
  self->current_preset_index = -1;
  for (double& gain : self->band_gains) {
    gain = 0.0;
  }
}

void ke_equalizer_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  ensure_gstreamer_initialized();
  KeEqualizerPlugin* plugin = KE_EQUALIZER_PLUGIN(
      g_object_new(ke_equalizer_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "ke_equalizer", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  plugin->event_channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "ke_equalizer/tone", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel, listen_cb,
                                       cancel_cb, g_object_ref(plugin),
                                       g_object_unref);

  g_object_unref(plugin);
}
