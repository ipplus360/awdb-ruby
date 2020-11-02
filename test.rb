# frozen_string_literal: true

require_relative './awdb/db.rb'


filename = '../IP_city_single_WGS84_awdb.awdb'
reader = AW::DB.new(filename)
loc = reader.get('166.111.4.100')

puts "#{loc['areacode']}"
puts "#{loc['continent']}"
puts loc
reader.close
