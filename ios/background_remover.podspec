#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint background_remover.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'background_remover'
  s.version          = '0.0.3'
  s.summary          = 'Flutter package that removes background of an image'
  s.description      = <<-DESC
Flutter package that removes background of an image using Apple Vision framework.
                       DESC
  s.homepage         = 'https://github.com/vinaykumarrock986612/background-remover'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Vinay Kumar' => 'vinaykumarrock986612@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
  s.frameworks       = 'CoreImage', 'Vision', 'UIKit'
end
