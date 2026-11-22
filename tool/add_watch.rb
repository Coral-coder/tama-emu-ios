#!/usr/bin/env ruby
# Adds the Apple Watch app (ios/TamaWatch: SwiftUI, the native Paradise core linked in) to
# ios/Runner.xcodeproj, embedded in the iPhone app's Watch folder. Idempotent. Run by CI after
# building the core for watchOS (tool/build_native.sh watchos).
require 'xcodeproj'

root = File.expand_path('..', __dir__)
proj_path = File.join(root, 'ios', 'Runner.xcodeproj')
project = Xcodeproj::Project.open(proj_path)
app = project.targets.find { |t| t.name == 'Runner' }
abort 'no Runner target' unless app
if project.targets.any? { |t| t.name == 'TamaWatch' }
  puts 'TamaWatch already in the project'
  exit 0
end

team = ENV['TEAM_ID'] || ''
app_bundle = ENV['BUNDLE_ID'] || 'com.lightwave.tama'
bundle = app_bundle + '.watchkitapp'
lib = '$(PROJECT_DIR)/../native/tama_core/target/watchos/libtama_core.a'

w = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << w
w.name = 'TamaWatch'
w.product_name = 'TamaWatch'
w.product_type = 'com.apple.product-type.application'
product = project.products_group.new_reference('TamaWatch.app', :built_products)
product.explicit_file_type = 'wrapper.application'
product.include_in_index = '0'
w.product_reference = product
w.build_configuration_list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
w.build_configuration_list.default_configuration_name = 'Release'
w.build_configuration_list.default_configuration_is_visible = '0'
%w[Debug Release Profile].each do |name|
  c = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  c.name = name
  c.build_settings = {
    'SDKROOT' => 'watchos',
    'SUPPORTED_PLATFORMS' => 'watchos watchsimulator',
    'WATCHOS_DEPLOYMENT_TARGET' => '9.0',
    'TARGETED_DEVICE_FAMILY' => '4',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => bundle,
    'APP_BUNDLE_ID' => app_bundle,
    'INFOPLIST_FILE' => 'TamaWatch/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'CODE_SIGN_STYLE' => 'Automatic',
    'DEVELOPMENT_TEAM' => team,
    'MARKETING_VERSION' => '1.0.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'SWIFT_VERSION' => '5.0',
    'SWIFT_OBJC_BRIDGING_HEADER' => 'TamaWatch/TamaWatch-Bridging-Header.h',
    'HEADER_SEARCH_PATHS' => ['$(inherited)', '$(PROJECT_DIR)/../native/tama_core/include'],
    'OTHER_LDFLAGS' => ['$(inherited)', '-force_load', lib],
    'DEAD_CODE_STRIPPING' => 'NO',
    'ENABLE_BITCODE' => 'NO',
    'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
  }
  w.build_configuration_list.build_configurations << c
end

group = project.main_group.new_group('TamaWatch', 'TamaWatch')
%w[TamaWatchApp.swift WatchLibrary.swift Console.swift GamesView.swift PhoneLink.swift].each do |f|
  w.source_build_phase.add_file_reference(group.new_reference(f))
end
group.new_reference('Info.plist')
group.new_reference('TamaWatch-Bridging-Header.h')
w.resources_build_phase.add_file_reference(group.new_reference('Assets.xcassets'))
w.frameworks_build_phase

# the iPhone app: build the watch app first and embed it in its Watch folder
app.add_dependency(w)
embed = app.new_copy_files_build_phase('Embed Watch Content')
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
bf = embed.add_file_reference(product)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
app.build_phases.delete(embed)
anchor = app.build_phases.index { |ph| ph.display_name == 'Embed Frameworks' } ||
         app.build_phases.index { |ph| ph.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) }
app.build_phases.insert(anchor + 1, embed)
puts 'app build phases: ' + app.build_phases.map(&:display_name).join(' | ')

project.save
puts "added TamaWatch (#{bundle}) to #{proj_path}"
