
module CPIO
  class ArchiveFormatError < IOError; end

  class ArchiveHeader
    Magic = '070707'
    Fields = [[6,  :magic   ],
              [6,  :dev     ],
              [6,  :inode   ],
              [6,  :mode    ],
              [6,  :uid     ],
              [6,  :gid     ],
              [6,  :numlinks],
              [6,  :rdev    ],
              [11, :mtime   ],
              [6,  :namesize],
              [11, :filesize]]
    
    HeaderSize = Fields.inject(0) do |sum,(size,name)|
      sum + size
    end
    
    HeaderUnpackFormat = Fields.collect do |size,name|
      "a%s" % size
    end.join('')
    
    Fields.each do |(size,name)|
      define_method(name) { @attrs[name.to_sym] }
    end

    def initialize(attrs)
      @attrs = attrs
    end

    def self.from(io)
      data = io.read(HeaderSize)
      verify_size(data)
      verify_magic(data)
      new(unpack_data(data))
    end

  private
    
    def self.verify_size(data)
      unless data.size == HeaderSize
        raise ArchiveFormatError, "Header is not long enough to be a valid CPIO archive with ASCII headers."
      end
    end

    def self.verify_magic(data)
      unless data[0..Magic.size - 1] == Magic
        raise ArchiveFormatError, "Archive does not seem to be a valid CPIO archive with ASCII headers."
      end
    end

    def self.unpack_data(data)
      contents = {}
      data.unpack(HeaderUnpackFormat).zip(Fields) do |(chunk,(size,name))|
        contents[name] = Integer(chunk)
      end
      contents
    end

  end

  class ArchiveEntry
    TrailerMagic = "TRAILER!!!"
    S_IFMT  = 0170000   # bitmask for the file type bitfields
    S_IFREG = 0100000   # regular file
    S_IFDIR = 0040000   # directory
    
    ExecutableMask = (0100 | # Owner executable
                      0010 | # Group executable
                      0001)  # Other executable

    attr_reader :filename, :data

    def self.from(io)
      header = ArchiveHeader.from(io)
      filename = read_filename(header, io)
      data = read_data(header, io) 
      new(header, filename, data)
    end
    
    def initialize(header, filename, data)
      @header = header
      @filename = filename
      @data = data
    end
    
    def trailer?
      @filename == TrailerMagic && @data.size == 0
    end
    
    def directory?
      mode & S_IFMT == S_IFDIR
    end

    def file?
      mode & S_IFMT == S_IFREG
    end

    def executable?
      (mode & ExecutableMask) != 0
    end
    
    def mode
      @mode ||= sprintf('%o', @header.mode).to_s.oct
    end

  private
    
    def self.read_filename(header, io)
      fname = io.read(header.namesize)
      if fname.size != header.namesize
        raise ArchiveFormatError, "Archive header seems to innacurately contain length of filename"
      end
      fname.chomp("\000")
    end

    def self.read_data(header, io)
      data = io.read(header.filesize)
      if data.size != header.filesize
        raise ArchiveFormatError, "Archive header seems to inaccurately contain length of the entry"
      end
      data
    end

  end

  class ArchiveReader
    
    def initialize(io)
      @io = io
    end

    def each_entry
      @io.rewind
      while (entry = ArchiveEntry.from(@io)) && !entry.trailer?
        yield(entry)
      end
    end

  end # ArchiveReader

end   # CPIO

if $PROGRAM_NAME == __FILE__
require 'stringio'
require 'test/unit'
require 'digest/sha1'

class CPIOArchiveReaderTest < Test::Unit::TestCase
  CPIOFixture = StringIO.new(DATA.read)
  # These are SHA1 hashes
  ExpectedFixtureHashes = { 'cpio_test/test_executable'    => '97bd38305a81f2d89b5f3aa44500ec964b87cf8a',
                            'cpio_test/test_dir/test_file' => 'e7f1aa55a7f83dc99c9978b91072d01a3f5c812e' }

  def test_given_a_archive_with_a_bad_magic_number_should_raise
    assert_raises(CPIO::ArchiveFormatError) do
      CPIO::ArchiveReader.new(StringIO.new('foo')).each_entry { }
    end
  end

  def test_given_a_archive_with_a_valid_magic_number_should_not_raise
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    assert_nil archive.each_entry { }
  end
  
  def test_given_a_valid_archive_should_have_the_expected_number_of_entries
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    entries = 4
    archive.each_entry { |ent| entries -= 1 }
    assert_equal 0, entries, "Expected #{entries} in the archive."
  end
  
  def test_given_a_valid_archive_should_have_the_expected_entry_filenames
    expected = %w[cpio_test cpio_test/test_dir cpio_test/test_dir/test_file cpio_test/test_executable]
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    archive.each_entry { |ent| expected.delete(ent.filename) }
    assert_equal 0, expected.size, "The expected array should be empty but we still have: #{expected.inspect}"
  end
  
  def test_given_a_valid_archive_should_have_the_expected_number_of_directories
    expected = 2
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    archive.each_entry { |ent| expected -= 1 if ent.directory? }
    assert_equal 0, expected
  end

  def test_given_a_valid_archive_should_have_the_expected_number_of_regular_files
    expected = 1
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    archive.each_entry { |ent| expected -= 1 if ent.file? && !ent.executable? }
    assert_equal 0, expected
  end

  def test_given_a_valid_archive_should_have_the_expected_number_of_executable_files
    expected = 1
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    archive.each_entry { |ent| expected -= 1 if ent.file? && ent.executable? }
    assert_equal 0, expected
  end

  def test_given_a_valid_archive_should_have_correct_file_contents
    expected = ExpectedFixtureHashes.size
    archive = CPIO::ArchiveReader.new(CPIOFixture)
    archive.each_entry do |ent|
      if (sha1_hash = ExpectedFixtureHashes[ent.filename]) && Digest::SHA1.hexdigest(ent.data) == sha1_hash
        expected -= 1
      end
    end
    assert_equal 0, expected, "Expected all files in the archive to hash correctly."
  end

end

end

__END__
0707077777770465470407550007650000240000040000001130242405100001200000000000cpio_test 0707077777770465520407550007650000240000030000001130242404300002300000000000cpio_test/test_dir 0707077777770465531006440007650000240000010000001130242637200003500000000016cpio_test/test_dir/test_file foobarbazbeep
0707077777770465541007550007650000240000010000001130242636000003200000000012cpio_test/test_executable foobarbaz
0707070000000000000000000000000000000000010000000000000000000001300000000000TRAILER!!!              
