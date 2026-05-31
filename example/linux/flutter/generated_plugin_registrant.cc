//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ke_equalizer/ke_equalizer_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) ke_equalizer_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "KeEqualizerPlugin");
  ke_equalizer_plugin_register_with_registrar(ke_equalizer_registrar);
}
