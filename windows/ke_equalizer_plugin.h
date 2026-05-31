#ifndef FLUTTER_PLUGIN_KE_EQUALIZER_PLUGIN_H_
#define FLUTTER_PLUGIN_KE_EQUALIZER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>

namespace ke_equalizer {

class KeEqualizerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  KeEqualizerPlugin();

  virtual ~KeEqualizerPlugin();

  // Disallow copy and assign.
  KeEqualizerPlugin(const KeEqualizerPlugin&) = delete;
  KeEqualizerPlugin& operator=(const KeEqualizerPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  struct CaptureState;

 private:
  flutter::EncodableMap CapabilitiesMap() const;
  flutter::EncodableMap EmptyStateMap() const;
  void StartToneAnalysis(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopToneAnalysis();

  std::unique_ptr<CaptureState> capture_state_;
};

}  // namespace ke_equalizer

#endif  // FLUTTER_PLUGIN_KE_EQUALIZER_PLUGIN_H_
