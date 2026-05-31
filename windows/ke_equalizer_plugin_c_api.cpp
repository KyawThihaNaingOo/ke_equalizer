#include "include/ke_equalizer/ke_equalizer_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "ke_equalizer_plugin.h"

void KeEqualizerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  ke_equalizer::KeEqualizerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
