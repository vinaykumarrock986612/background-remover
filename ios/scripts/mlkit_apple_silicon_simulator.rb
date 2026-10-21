# Enables Google ML Kit on Apple Silicon simulators whose runtime does not ship
# Rosetta. Google currently distributes arm64 device and x86_64 simulator
# slices, but its arm64 framework slice is labelled as iOS rather than iOS
# Simulator. This script toggles only that Mach-O platform label before every
# build, so the same Pods installation remains valid for both devices and
# simulators.

require 'fileutils'

module BackgroundRemoverMLKitSimulator
  ARM64_CPU_TYPE = 0x0100_000c
  FAT_MAGIC = 0xcafe_babe
  MACHO_64_MAGIC = 0xfeed_facf
  LC_BUILD_VERSION = 0x32
  IOS_PLATFORM = 2
  IOS_SIMULATOR_PLATFORM = 7
  ARCHIVE_MAGIC = "!<arch>\n".b
  ARCHIVE_HEADER_SIZE = 60

  module_function

  def patch(pods_root, platform_name)
    desired_platform = platform_name == 'iphonesimulator' ? IOS_SIMULATOR_PLATFORM : IOS_PLATFORM
    binaries = framework_binaries(pods_root)
    abort '[background_remover] No ML Kit framework binaries were found.' if binaries.empty?

    changed = binaries.map do |binary|
      patch_binary(binary, desired_platform)
    end.inject(0, :+)
    puts "[background_remover] Prepared ML Kit arm64 slice for #{platform_name} (#{changed} object(s) updated)."
  end

  def framework_binaries(pods_root)
    patterns = [
      File.join(pods_root, 'MLImage', 'Frameworks', '*.framework'),
      File.join(pods_root, 'MLKit*', 'Frameworks', '*.framework'),
    ]

    patterns.flat_map { |pattern| Dir.glob(pattern) }.map do |framework|
      binary = File.join(framework, File.basename(framework, '.framework'))
      binary if File.file?(binary)
    end.compact
  end

  def patch_binary(path, desired_platform)
    bytes = File.binread(path)
    arm64_slice_offset = fat_arm64_slice_offset(bytes)
    return 0 unless arm64_slice_offset

    changed = if bytes.byteslice(arm64_slice_offset, ARCHIVE_MAGIC.bytesize) == ARCHIVE_MAGIC
                patch_archive(bytes, arm64_slice_offset, desired_platform)
              else
                patch_macho(bytes, arm64_slice_offset, desired_platform)
              end

    File.binwrite(path, bytes) if changed.positive?
    changed
  end

  def fat_arm64_slice_offset(bytes)
    return nil unless bytes.bytesize >= 8
    return nil unless read_u32_be(bytes, 0) == FAT_MAGIC

    count = read_u32_be(bytes, 4)
    count.times do |index|
      entry = 8 + index * 20
      break if entry + 20 > bytes.bytesize
      return read_u32_be(bytes, entry + 8) if read_u32_be(bytes, entry) == ARM64_CPU_TYPE
    end
    nil
  end

  def patch_archive(bytes, offset, desired_platform)
    position = offset + ARCHIVE_MAGIC.bytesize
    changed = 0

    while position + ARCHIVE_HEADER_SIZE <= bytes.bytesize
      header = bytes.byteslice(position, ARCHIVE_HEADER_SIZE)
      break unless header.byteslice(58, 2) == "`\n"

      member_size = header.byteslice(48, 10).strip.to_i
      member_offset = position + ARCHIVE_HEADER_SIZE
      break if member_offset + member_size > bytes.bytesize

      # BSD ar stores long filenames immediately before the member contents.
      # Their byte count is part of member_size, so skip it before looking for
      # the Mach-O magic (the MLImage archive uses this representation).
      name = header.byteslice(0, 16).strip
      filename_size = name.start_with?('#1/') ? name.delete_prefix('#1/').to_i : 0
      macho_offset = member_offset + filename_size
      changed += patch_macho(bytes, macho_offset, desired_platform) if filename_size <= member_size
      position = member_offset + member_size
      position += 1 if position.odd?
    end
    changed
  end

  def patch_macho(bytes, offset, desired_platform)
    return 0 if offset + 32 > bytes.bytesize
    return 0 unless read_u32_le(bytes, offset) == MACHO_64_MAGIC

    command_count = read_u32_le(bytes, offset + 16)
    position = offset + 32
    changed = 0

    command_count.times do
      break if position + 8 > bytes.bytesize
      command = read_u32_le(bytes, position)
      command_size = read_u32_le(bytes, position + 4)
      break if command_size < 8 || position + command_size > bytes.bytesize

      if command == LC_BUILD_VERSION && command_size >= 12
        current_platform = read_u32_le(bytes, position + 8)
        if [IOS_PLATFORM, IOS_SIMULATOR_PLATFORM].include?(current_platform) && current_platform != desired_platform
          bytes[position + 8, 4] = [desired_platform].pack('V')
          changed += 1
        end
      end
      position += command_size
    end
    changed
  end

  def read_u32_be(bytes, offset)
    bytes.byteslice(offset, 4).unpack1('N')
  end

  def read_u32_le(bytes, offset)
    bytes.byteslice(offset, 4).unpack1('V')
  end
end

def background_remover_mlkit_apple_silicon_simulator_patch(installer)
  pods_root = installer.sandbox.root.to_s
  patcher = File.join(pods_root, 'background_remover_mlkit_apple_silicon_simulator.rb')
  FileUtils.cp(__FILE__, patcher)

  # ML Kit's podspec excludes arm64 from Simulator builds. Remove that single
  # generated setting after Pod installation; the build-phase patch above makes
  # the arm64 slice safe to link for simulators.
  Dir.glob(File.join(pods_root, 'Target Support Files', '**', '*.xcconfig')).each do |xcconfig|
    contents = File.read(xcconfig)
    updated = contents.gsub(/^EXCLUDED_ARCHS\[sdk=iphonesimulator\*\]\s*=\s*arm64\s*\n/, '')
    File.write(xcconfig, updated) unless updated == contents
  end

  installer.pods_project.targets.each do |target|
    next unless target.name.start_with?('Pods-')

    phase_name = 'Prepare ML Kit arm64 simulator slice'
    phase = target.shell_script_build_phases.find { |item| item.name == phase_name }
    phase ||= target.new_shell_script_build_phase(phase_name)
    phase.shell_path = '/bin/sh'
    phase.shell_script = <<~SCRIPT
      set -euo pipefail
      /usr/bin/ruby "${PODS_ROOT}/background_remover_mlkit_apple_silicon_simulator.rb" "${PLATFORM_NAME}" "${PODS_ROOT}"
    SCRIPT
    phase.show_env_vars_in_log = '0'
    phase.always_out_of_date = '1'
  end
end

if $PROGRAM_NAME == __FILE__
  platform_name, pods_root = ARGV
  abort 'Usage: mlkit_apple_silicon_simulator.rb <platform> <pods_root>' unless platform_name && pods_root
  BackgroundRemoverMLKitSimulator.patch(pods_root, platform_name)
end
