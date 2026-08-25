require "fileutils"
require "xcodeproj"

work_dir, repository_dir, linkage = ARGV
abort "usage: generate_project.rb WORK_DIR REPOSITORY_DIR LINKAGE" unless work_dir && repository_dir && linkage

framework_directive = case linkage
                      when "static-library" then nil
                      when "static-framework" then "use_frameworks! :linkage => :static"
                      when "dynamic-framework" then "use_frameworks! :linkage => :dynamic"
                      else abort "unsupported linkage: #{linkage}"
                      end

FileUtils.mkdir_p(work_dir)
test_source = File.join(repository_dir, "Tests/CocoaPodsRuntime/BottomSheetRuntimeTests.swift")
FileUtils.cp(test_source, work_dir)

project_path = File.join(work_dir, "CocoaPodsRuntime.xcodeproj")
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:unit_test_bundle, "CocoaPodsRuntimeTests", :ios, "14.0")
source = project.main_group.new_file(File.join(work_dir, "BottomSheetRuntimeTests.swift"))
target.source_build_phase.add_file_reference(source)

target.build_configurations.each do |configuration|
  configuration.build_settings["CODE_SIGNING_ALLOWED"] = "NO"
  configuration.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  configuration.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.rownd.CocoaPodsRuntimeTests"
  configuration.build_settings["SWIFT_VERSION"] = "5.0"
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(project_path, "CocoaPodsRuntime", true)

File.write(File.join(work_dir, "Podfile"), <<~PODFILE)
  platform :ios, '14.0'
  #{framework_directive}

  target 'CocoaPodsRuntimeTests' do
    pod 'RowndSupertokens', :path => #{repository_dir.inspect}
  end

  post_install do |installer|
    installer.pods_project.targets.each do |target|
      target.build_configurations.each do |configuration|
        configuration.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
      end
    end
  end
PODFILE
