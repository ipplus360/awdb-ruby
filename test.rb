# frozen_string_literal: true

require_relative './awdb/db.rb'


filename = 'D:\\IP_city_2020W12_single_WGS84.awdb'
reader = AW::DB.new(filename)
loc = reader.get('166.111.4.100')
loc.each do |key, value|
    if key == "multiAreas"
        for area in value do
            area.each do |key_area, value_area|
                print "\t", key_area, " -> ", value_area, "\n"
            end
        end 
    else
        print key, " --> ", value, "\n"
    end
end
reader.close
