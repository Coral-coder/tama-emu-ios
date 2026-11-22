#!/usr/bin/env ruby
# Adds the USB serial driver (ios/TamaSerialDriver, a DriverKit extension) to ios/Runner.xcodeproj:
# a driver-extension target, embedded in the app, built before it, and the app's entitlement to
# talk to drivers. Idempotent. Run by CI before archiving (tool/add_driverkit.rb).
require 'xcodeproj'

root = File.expand_path('..', __dir__)
proj_path = File.join(root, 'ios', 'Runner.xcodeproj')
project = Xcodeproj::Project.open(proj_path)
app = project.targets.find { |t| t.name == 'Runner' }
abort 'no Runner target' unless app
if project.targets.any? { |t| t.name == 'TamaSerialDriver' }
  puts 'TamaSerialDriver already in the project'
  exit 0
end

team = ENV['TEAM_ID'] || ''
bundle = (ENV['BUNDLE_ID'] || 'com.lightwave.tama') + '.serial'

dext = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
project.targets << dext
dext.name = 'TamaSerialDriver'
dext.product_name = 'TamaSerialDriver'
dext.product_type = 'com.apple.product-type.driver-extension'
product = project.products_group.new_reference('TamaSerialDriver.dext', :built_products)
product.explicit_file_type = 'wrapper.driver-extension'
product.include_in_index = '0'
dext.product_reference = product
dext.build_configuration_list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
dext.build_configuration_list.default_configuration_name = 'Release'
dext.build_configuration_list.default_configuration_is_visible = '0'
%w[Debug Release Profile].each do |name|
  c = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  c.name = name
  c.build_settings = {
    'SDKROOT' => 'driverkit',
    'SUPPORTED_PLATFORMS' => 'driverkit',
    'DRIVERKIT_DEPLOYMENT_TARGET' => '22.0',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => bundle,
    'INFOPLIST_FILE' => 'TamaSerialDriver/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'TamaSerialDriver/TamaSerialDriver.entitlements',
    'CODE_SIGN_STYLE' => 'Automatic',
    'DEVELOPMENT_TEAM' => team,
    'MARKETING_VERSION' => '1.0.0',
    'CURRENT_PROJECT_VERSION' => '0',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++20',
    'SKIP_INSTALL' => 'YES',
    'RUN_CLANG_STATIC_ANALYZER' => 'NO',
    'OTHER_LDFLAGS' => ['$(inherited)', '-framework', 'DriverKit', '-framework', 'USBDriverKit'],
  }
  dext.build_configuration_list.build_configurations << c
end

group = project.main_group.new_group('TamaSerialDriver', 'TamaSerialDriver')
sources = dext.source_build_phase
%w[TamaSerialDriver.iig TamaSerialUserClient.iig TamaSerialDriver.cpp TamaSerialUserClient.cpp].each do |f|
  sources.add_file_reference(group.new_reference(f))
end
group.new_reference('Info.plist')
group.new_reference('TamaSerialDriver.entitlements')
dext.frameworks_build_phase
dext.resources_build_phase

# the app: build the driver first and embed it in the bundle's SystemExtensions folder
app.add_dependency(dext)
embed = app.new_copy_files_build_phase('Embed Driver Extensions')
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(SYSTEM_EXTENSIONS_FOLDER_PATH)'
bf = embed.add_file_reference(product)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
# Right after the app's own "Embed Frameworks", before Flutter's script phases ("Thin Binary"
# has no declared outputs: a copy phase behind it makes a dependency cycle).
app.build_phases.delete(embed)
anchor = app.build_phases.index { |ph| ph.display_name == 'Embed Frameworks' } ||
         app.build_phases.index { |ph| ph.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) }
app.build_phases.insert(anchor + 1, embed)
puts 'app build phases: ' + app.build_phases.map(&:display_name).join(' | ')

app.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

project.save
puts "added TamaSerialDriver (#{bundle}) to #{proj_path}"
