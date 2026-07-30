# Generates SatellicaRecorder.xcodeproj: app + broadcast extension targets.
require 'xcodeproj'
require 'fileutils'

root = File.expand_path(File.dirname(__FILE__))
proj_path = File.join(root, 'SatellicaRecorder.xcodeproj')
File.exist?(proj_path) && FileUtils.rm_rf(proj_path)

APP_ID       = 'com.musiciansfriend.mobile.app'
BROADCAST_ID = 'com.musiciansfriend.mobile.app.broadcast'
TEAM         = ENV['DEVELOPMENT_TEAM'] || '44D3SM5LR3'

project = Xcodeproj::Project.new(proj_path)

# ---- App target ----
app = project.new_target(:application, 'SatellicaRecorder', :ios, '17.0')
app.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = APP_ID
  s['PRODUCT_NAME'] = 'SatellicaRecorder'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_FILE'] = 'App/Info.plist'
  s['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  s['INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents'] = 'YES'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Satellica Recorder'
  s['INFOPLIST_KEY_UISupportedInterfaceOrientations'] = 'UIInterfaceOrientationPortrait'
  s['INFOPLIST_KEY_NSMicrophoneUsageDescription'] = 'Satellica Recorder uses the microphone to capture your voice during screen recording sessions.'
  s['ENABLE_PREVIEWS'] = 'YES'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGN_ENTITLEMENTS'] = 'App/SatellicaRecorder.entitlements'
  s['DEVELOPMENT_TEAM'] = TEAM if TEAM && !TEAM.empty?
end

# ---- Broadcast Extension target ----
broadcast = project.new_target(:app_extension, 'BroadcastExtension', :ios, '17.0')
broadcast.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BROADCAST_ID
  s['PRODUCT_NAME'] = 'BroadcastExtension'
  s['MARKETING_VERSION'] = '1.0'
  s['CURRENT_PROJECT_VERSION'] = '1'
  s['SWIFT_VERSION'] = '5.0'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['GENERATE_INFOPLIST_FILE'] = 'YES'
  s['INFOPLIST_FILE'] = 'BroadcastExtension/Info.plist'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'Satellica Broadcast'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['CODE_SIGN_ENTITLEMENTS'] = 'BroadcastExtension/BroadcastExtension.entitlements'
  s['SKIP_INSTALL'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
  s['DEVELOPMENT_TEAM'] = TEAM if TEAM && !TEAM.empty?
end

# ---- Sources ----
def add_sources(project, target, group, dir, glob)
  Dir.glob(File.join(dir, glob)).sort.each do |f|
    ref = group.new_file(f)
    target.source_build_phase.add_file_reference(ref)
  end
end

# Shared sources → compiled into BOTH targets
shared_group = project.main_group.new_group('Shared', 'Shared')
Dir.glob(File.join(root, 'Shared', '*.swift')).sort.each do |f|
  ref = shared_group.new_file(f)
  app.source_build_phase.add_file_reference(ref)
  broadcast.source_build_phase.add_file_reference(ref)
end

# App sources
app_group = project.main_group.new_group('App', 'App')
add_sources(project, app, app_group, File.join(root, 'App'), '**/*.swift')

# Broadcast sources
broadcast_group = project.main_group.new_group('BroadcastExtension', 'BroadcastExtension')
add_sources(project, broadcast, broadcast_group, File.join(root, 'BroadcastExtension'), '*.swift')

# ---- Embed extension into app ----
app.add_dependency(broadcast)
embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(broadcast.product_reference, true)

# ---- Scheme ----
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'SatellicaRecorder', true)

project.save
puts "Generated #{proj_path}"
puts "App sources: #{app.source_build_phase.files.count}, Broadcast sources: #{broadcast.source_build_phase.files.count}"
