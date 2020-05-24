# Uncomment the next line to define a global platform for your project
# platform :ios, '9.0'

use_frameworks!

# ignore all warnings from all pods
inhibit_all_warnings!

workspace 'Midnightios'

project 'Midnightios'
project 'MidnightSDK'

def sdk_pods
    pod 'SwiftWebSocket', '~> 2.7.0'
end

def db_pods
    pod 'SQLite.swift', '~> 0.12.0'
end

def ui_pods
    pod 'SwiftKeychainWrapper', '~> 3.2'
    pod 'Firebase/Messaging'
    pod 'Firebase/Analytics'
    pod 'PhoneNumberKit', '~> 3.1'
end

target 'MidnightSDK' do
    project 'MidnightSDK'
    sdk_pods
end

target 'MidnightSDKTests' do
    project 'MidnightSDK'
    sdk_pods
end

target 'MidnightiosDB' do
    project 'MidnightiosDB'
    db_pods
end

target 'Midnightios' do
    project 'Midnightios'
    sdk_pods
    ui_pods
    db_pods
    # Pods for Crashlytics
    pod 'Fabric', '~> 1.10.2'
    pod 'Crashlytics', '~> 3.13.4'
end

post_install do | installer |
  require 'fileutils'
  FileUtils.cp_r('Pods/Target Support Files/Pods-Midnightios/Pods-Midnightios-acknowledgements.plist', 'Midnightios/Settings.bundle/Acknowledgements.plist', :remove_destination => true)
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.xcconfigs.each do |config_name, config_file|
      xcconfig_path = aggregate_target.xcconfig_path(config_name)
      config_file.save_as(xcconfig_path)
    end
  end
end
