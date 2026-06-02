Pod::Spec.new do |s|
  s.name             = "Rownd"
  s.version          = "3.14.10"
  s.summary          = "Rownd bindings for iOS"
  s.description      = <<-DESC
                        Rownd is a user management platform designed to make authentication
                        and user lifecycle easy, frictionless, and seamless for both devs and end-users
                        DESC
  s.homepage         = "https://github.com/rownd/ios"
  s.license          = { :type => "Apache 2.0", :file => "LICENSE.txt" }
  s.author           = {
    "Rownd" => "support@rownd.io",
  }
  s.documentation_url = "https://github.com/rownd/ios"
  s.source            = {
    :git => "https://github.com/rownd/ios.git",
    :tag => s.version.to_s
  }

  s.ios.deployment_target     = '14.0'

  s.dependency 'JWTDecode', '~> 3.0.0'
  s.dependency 'ReSwift', '~> 6.1.1'
  s.dependency 'ReSwiftThunk', '~> 2.0.1'
  s.dependency 'SwiftKeychainWrapper', '~> 4.0.1'
  s.dependency 'Get', '~> 2.2.0'
  s.dependency 'GoogleSignIn', '~> 7.0.0'
  s.dependency 'lottie-ios', '~> 4.5.0'
  s.dependency 'Factory', '~> 1.2.8'
  s.dependency 'SuperTokensIOS', '~> 0.4.2'

  s.dependency 'LBBottomSheet'
  s.dependency 'AnyCodable'
  s.dependency 'GzipSwift'

  s.subspec 'LBBottomSheet' do |ss|
    ss.source_files = 'Packages/LBBottomSheet/Sources/**/*'
  end

  s.subspec 'AnyCodable' do |ss|
    ss.source_files = 'Packages/AnyCodable/Sources/**/*'
  end
  
  s.requires_arc     = true
  
  s.source_files     = 'Sources/**/*'
  s.swift_versions   = [ "5.5", "5.4", "5.3", "5.2", "5.0" ]

end
