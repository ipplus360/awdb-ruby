# frozen_string_literal: true

require 'ipaddr'
require_relative  './decoder.rb'
require_relative  './errors.rb'
require_relative  './file_reader.rb'
require_relative  './memory_reader.rb'
require_relative  './metadata.rb'

module AW

  class DB
    # Choose the default method to open the database. Currently the default is
    # MODE_FILE.
    MODE_AUTO = :MODE_AUTO
    # Open the database as a regular file and read on demand.
    MODE_FILE = :MODE_FILE
    # Read the database into memory. This is faster than MODE_FILE but causes
    # increased memory use.
    MODE_MEMORY = :MODE_MEMORY
    # Treat the database parameter as containing a database already read into
    # memory. It must be a binary string. This primarily exists for testing.
    #
    # @!visibility private
    MODE_PARAM_IS_BUFFER = :MODE_PARAM_IS_BUFFER

    DATA_SECTION_SEPARATOR_SIZE = 16
    private_constant :DATA_SECTION_SEPARATOR_SIZE
    ####edit
    METADATA_START_MARKER = "\xAB\xCD\xEFipplus360.com".b.freeze
    private_constant :METADATA_START_MARKER
    ####edit
    METADATA_START_MARKER_LENGTH = 16
    private_constant :METADATA_START_MARKER_LENGTH
    METADATA_MAX_SIZE = 131_072
    private_constant :METADATA_MAX_SIZE

    attr_reader :metadata

    def initialize(database, options = {})
      options[:mode] = MODE_AUTO unless options.key?(:mode)

      case options[:mode]
      when MODE_AUTO, MODE_FILE
        @io = FileReader.new(database)
      when MODE_MEMORY
        @io = MemoryReader.new(database)
      when MODE_PARAM_IS_BUFFER
        @io = MemoryReader.new(database, is_buffer: true)
      else
        raise ArgumentError, 'Invalid mode'
      end

      begin
        @size = @io.size

        metadata_start = find_metadata_start
        metadata_decoder = Decoder.new(@io, metadata_start)
        metadata_map, = metadata_decoder.decode(metadata_start)
        @metadata = Metadata.new(metadata_map)
        @decoder = Decoder.new(@io, @metadata.search_tree_size +
                               DATA_SECTION_SEPARATOR_SIZE)

        # Store copies as instance variables to reduce method calls.
        @ip_version       = @metadata.ip_version
        @node_count       = @metadata.node_count
        @node_byte_size   = @metadata.node_byte_size
        @record_size      = @metadata.record_size
        @search_tree_size = @metadata.search_tree_size

        @ipv4_start = nil
        # Find @ipv4_start up front. If we don't, we either have a race to
        # get/set it or have to synchronize access.
        start_node(0)
      rescue StandardError => e
        @io.close
        raise e
      end
    end

    def get(ip_address)
      record, = get_with_prefix_length(ip_address)

      record
    end

    def get_with_prefix_length(ip_address)
      ip = IPAddr.new(ip_address)
      # We could check the IP has the correct prefix (32 or 128) but I do not
      # for performance reasons.

      ip_version = ip.ipv6? ? 6 : 4
      if ip_version == 6 && @ip_version == 4
        raise ArgumentError,
              "Error looking up #{ip}. You attempted to look up an IPv6 address in an IPv4-only database."
      end

      pointer, depth = find_address_in_tree(ip, ip_version)
      return nil, depth if pointer == 0

      [resolve_data_pointer(pointer), depth]
    end

    private

    IP_VERSION_TO_BIT_COUNT = {
      4 => 32,
      6 => 128,
    }.freeze
    private_constant :IP_VERSION_TO_BIT_COUNT

    def find_address_in_tree(ip_address, ip_version)
      packed = ip_address.hton

      bit_count = IP_VERSION_TO_BIT_COUNT[ip_version]
      node = start_node(bit_count)

      node_count = @node_count

      depth = 0
      loop do
        break if depth >= bit_count || node >= node_count

        c = packed[depth >> 3].ord
        bit = 1 & (c >> 7 - (depth % 8))
        node = read_node(node, bit)
        depth += 1
      end

      return 0, depth if node == node_count

      return node, depth if node > node_count

      raise InvalidDatabaseError, 'Invalid node in search tree'
    end

    def start_node(length)
      return 0 if @ip_version != 6 || length == 128

      return @ipv4_start if @ipv4_start

      node = 0
      96.times do
        break if node >= @metadata.node_count

        node = read_node(node, 0)
      end

      @ipv4_start = node
    end

    # Read a record from the indicated node. Index indicates whether it's the
    # left (0) or right (1) record.
    #
    # rubocop:disable Metrics/CyclomaticComplexity
    def read_node(node_number, index)
      base_offset = node_number * @node_byte_size

      if @record_size == 24
        offset = index == 0 ? base_offset : base_offset + 3
        buf = @io.read(offset, 3)
        node_bytes = "\x00".b << buf
        return node_bytes.unpack1('N')
      end

      if @record_size == 28
        if index == 0
          buf = @io.read(base_offset, 4)
          n = buf.unpack1('N')
          last24 = n >> 8
          first4 = (n & 0xf0) << 20
          return first4 | last24
        end
        buf = @io.read(base_offset + 3, 4)
        return buf.unpack1('N') & 0x0fffffff
      end

      if @record_size == 32
        offset = index == 0 ? base_offset : base_offset + 4
        node_bytes = @io.read(offset, 4)
        return node_bytes.unpack1('N')
      end

      raise InvalidDatabaseError, "Unsupported record size: #{@record_size}"
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    def resolve_data_pointer(pointer)
      offset_in_file = pointer - @node_count + @search_tree_size

      if offset_in_file >= @size
        raise InvalidDatabaseError,
              'The AW DB file\'s search tree is corrupt'
      end

      data, = @decoder.decode(offset_in_file)
      data
    end

    def find_metadata_start
      metadata_max_size = @size < METADATA_MAX_SIZE ? @size : METADATA_MAX_SIZE

      stop_index = @size - metadata_max_size
      index = @size - METADATA_START_MARKER_LENGTH
      while index >= stop_index
        return index + METADATA_START_MARKER_LENGTH if at_metadata?(index)

        index -= 1
      end

      raise InvalidDatabaseError,
            'Metadata section not found. Is this a valid AW DB file?'
    end

    def at_metadata?(index)
      @io.read(index, METADATA_START_MARKER_LENGTH) == METADATA_START_MARKER
    end

    public

    # Close the DB and return resources to the system.
    #
    # @return [void]
    def close
      @io.close
    end
  end
end
