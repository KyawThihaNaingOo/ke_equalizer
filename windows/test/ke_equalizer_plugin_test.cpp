#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "ke_equalizer_plugin.h"

namespace ke_equalizer {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

}  // namespace

TEST(KeEqualizerPlugin, GetPlatformVersion) {
  KeEqualizerPlugin plugin;
  // Save the reply value from the success callback.
  std::string result_string;
  plugin.HandleMethodCall(
      MethodCall("getPlatformVersion", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_string](const EncodableValue* result) {
            result_string = std::get<std::string>(*result);
          },
          nullptr, nullptr));

  // Since the exact string varies by host, just ensure that it's a string
  // with the expected format.
  EXPECT_TRUE(result_string.rfind("Windows ", 0) == 0);
}

TEST(KeEqualizerPlugin, GetCapabilities) {
  KeEqualizerPlugin plugin;
  EncodableMap result_map;
  plugin.HandleMethodCall(
      MethodCall("getCapabilities", std::make_unique<EncodableValue>()),
      std::make_unique<MethodResultFunctions<>>(
          [&result_map](const EncodableValue* result) {
            result_map = std::get<EncodableMap>(*result);
          },
          nullptr, nullptr));

  EXPECT_EQ(std::get<bool>(
                result_map[EncodableValue("supportsPlaybackEqualizer")]),
            false);
  EXPECT_EQ(std::get<bool>(result_map[EncodableValue("supportsToneAnalysis")]),
            true);
  EXPECT_EQ(std::get<bool>(result_map[EncodableValue("supportsRecording")]),
            false);
  EXPECT_EQ(std::get<std::string>(result_map[EncodableValue("platform")]),
            "windows");
}

}  // namespace test
}  // namespace ke_equalizer
