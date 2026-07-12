# frozen_string_literal: true

# Packages ParaFrame into an installable .rbz archive.
#
# An .rbz is a plain ZIP whose top level holds the registration file and the
# support folder:
#
#   ParaFrame_0.1.0.rbz
#   ├── paraframe.rb
#   └── paraframe/…
#
# Usage (from the repository root, plain system Ruby — no gems needed):
#
#   ruby build/package.rb                 # package current VERSION
#   ruby build/package.rb --bump patch    # 0.1.0 -> 0.1.1, then package
#   ruby build/package.rb --bump minor    # 0.1.0 -> 0.2.0, then package
#   ruby build/package.rb --bump major    # 0.1.0 -> 1.0.0, then package
#
# The archive is written to dist/. The ZIP is produced by the minimal
# pure-Ruby writer below (zlib is part of Ruby's stdlib) so packaging works
# identically on Windows and macOS with no external tools.
#
# Note: this produces an UNSIGNED archive. Signing for Extension Warehouse is
# a manual upload on the SketchUp developer portal — see README.md.

require 'zlib'
require 'fileutils'

module Kopji
  module ParaFrameBuild

    ROOT         = File.expand_path('..', __dir__)
    LOADER_FILE  = File.join(ROOT, 'paraframe.rb')
    SUPPORT_DIR  = File.join(ROOT, 'paraframe')
    DIST_DIR     = File.join(ROOT, 'dist')

    # Files never shipped inside the .rbz.
    EXCLUDE = ['.gitkeep', '.DS_Store', 'Thumbs.db'].freeze

    module_function

    # ------------------------------------------------------------ versioning

    def read_version
      src = File.read(LOADER_FILE, encoding: 'UTF-8')
      m = src.match(/^\s*VERSION\s*=\s*'(\d+)\.(\d+)\.(\d+)'/)
      abort "Could not find VERSION = 'x.y.z' in #{LOADER_FILE}" unless m
      m.captures.map(&:to_i)
    end

    def write_version(major, minor, patch)
      version = "#{major}.#{minor}.#{patch}"
      src = File.read(LOADER_FILE, encoding: 'UTF-8')
      src.sub!(/^(\s*VERSION\s*=\s*)'\d+\.\d+\.\d+'/, "\\1'#{version}'")
      File.write(LOADER_FILE, src, encoding: 'UTF-8')
      version
    end

    def bump(kind)
      major, minor, patch = read_version
      case kind
      when 'major' then major += 1; minor = 0; patch = 0
      when 'minor' then minor += 1; patch = 0
      when 'patch' then patch += 1
      else abort "Unknown bump kind '#{kind}' (use major, minor or patch)"
      end
      version = write_version(major, minor, patch)
      puts "Version bumped to #{version}"
      version
    end

    # -------------------------------------------------- minimal ZIP writing
    # Just enough of the ZIP format (PKWARE APPNOTE) for an .rbz: local file
    # headers + deflated data, then a central directory and the end record.

    class ZipWriter
      def initialize(io)
        @io = io
        @central = []
      end

      # @param name [String] forward-slash path inside the archive
      # @param data [String] raw file bytes
      def add(name, data)
        data   = data.b
        crc    = Zlib.crc32(data)
        packed = deflate_raw(data)
        # Fall back to "stored" if deflate did not help (tiny/compressed files).
        method = packed.bytesize < data.bytesize ? 8 : 0
        packed = data if method.zero?

        offset = @io.pos
        dos_time, dos_date = dos_datetime(Time.now)
        header = [0x04034b50, 20, 0, method, dos_time, dos_date, crc,
                  packed.bytesize, data.bytesize, name.bytesize, 0]
        @io.write(header.pack('Vv5V3v2') + name + packed)

        @central << [name, method, dos_time, dos_date, crc,
                     packed.bytesize, data.bytesize, offset]
      end

      def close
        cd_offset = @io.pos
        @central.each do |name, method, dos_time, dos_date, crc, csize, usize, offset|
          header = [0x02014b50, 20, 20, 0, method, dos_time, dos_date, crc,
                    csize, usize, name.bytesize, 0, 0, 0, 0, 0, offset]
          @io.write(header.pack('Vv6V3v5V2') + name)
        end
        cd_size = @io.pos - cd_offset
        eocd = [0x06054b50, 0, 0, @central.size, @central.size,
                cd_size, cd_offset, 0]
        @io.write(eocd.pack('Vv4V2v'))
      end

      private

      # Raw deflate stream (negative window bits = no zlib wrapper), as the
      # ZIP format requires.
      def deflate_raw(data)
        z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        out = z.deflate(data, Zlib::FINISH)
        z.close
        out
      end

      def dos_datetime(t)
        time = (t.hour << 11) | (t.min << 5) | (t.sec / 2)
        date = ((t.year - 1980) << 9) | (t.month << 5) | t.day
        [time, date]
      end
    end

    # -------------------------------------------------------------- package

    def collect_files
      files = [LOADER_FILE]
      files += Dir.glob(File.join(SUPPORT_DIR, '**', '*'), File::FNM_DOTMATCH)
                  .select { |f| File.file?(f) }
      files.reject { |f| EXCLUDE.include?(File.basename(f)) }
    end

    def package
      version = read_version.join('.')
      FileUtils.mkdir_p(DIST_DIR)
      rbz = File.join(DIST_DIR, "ParaFrame_#{version}.rbz")

      File.open(rbz, 'wb') do |io|
        zip = ZipWriter.new(io)
        collect_files.sort.each do |file|
          # Archive paths are relative to the repo root, forward slashes.
          name = file.sub("#{ROOT}/", '').tr('\\', '/')
          zip.add(name, File.binread(file))
          puts "  + #{name}"
        end
        zip.close
      end

      puts "Wrote #{rbz} (#{File.size(rbz)} bytes)"
      rbz
    end

  end
end

if __FILE__ == $PROGRAM_NAME
  if (i = ARGV.index('--bump'))
    Kopji::ParaFrameBuild.bump(ARGV[i + 1].to_s)
  end
  Kopji::ParaFrameBuild.package
end
