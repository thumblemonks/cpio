
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

    def self.from(io)
      header = ArchiveHeader.from(io)
      filename = read_filename(header, io)
      data = read_data(header, io) 
      if data.size != header.filesize
        raise ArchiveFormatError, "Archive header seems to inaccurately contain length of the entry"
      end
      new(header, filename, data)
    end
    
    def initialize(header, filename, data)
      @header = header
      @filename = filename.chomp("\000")
      @data = data
    end
    
    def trailer?
      @filename == TrailerMagic && @data.size == 0
    end

  private
    
    def self.read_filename(header, io)
      io.read(header.namesize)
    end

    def self.read_data(header, io)
      io.read(header.filesize)
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

class CPIOArchiveReaderTest < Test::Unit::TestCase

  def test_given_a_archive_with_a_bad_magic_number_should_raise
    assert_raises(CPIO::ArchiveFormatError) do
      CPIO::ArchiveReader.new(StringIO.new('foo'))
    end
  end

  def test_given_a_archive_with_a_valid_magic_number_should_not_raise
  end

end

end
