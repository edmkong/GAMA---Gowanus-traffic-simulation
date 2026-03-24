model public_parking_garages

global {
    // Update the relative path to where you put the shapefile
    file public_parking_file <- shape_file("../includes/public_parking_facilities.shp");

    action load_public_parking_garages {
        create public_parking_garage from: public_parking_file with: [
            garage_name::string(read("name")),
            garage_address::string(read("address")),
            sub_area::string(read("sub_area")),
            map_no::int(read("map_no")),
            license_no::string(read("lic_no")),
            licensed_capacity::int(read("lic_cap")),
            midday_util_raw::string(read("mid_util"))
        ];
    }
}

species public_parking_garage {

    string garage_name;
    string garage_address;
    string sub_area;
    int map_no;
    string license_no;

    int licensed_capacity;
    string midday_util_raw;

    // "100%" -> 1.0, "61%" -> 0.61, etc.
    float midday_utilization <- float(replace(midday_util_raw, "%", "")) / 100.0;

    // Initial state derived from capacity + midday utilization
    int occupied_spots <- int((licensed_capacity * midday_utilization) + 0.5);
    int available_spots <- licensed_capacity - occupied_spots;

    rgb garage_color <- #orange;

    aspect geom {
        // Because the shapefile is point-based, a circle is easier to see than draw shape
        draw triangle(100) color: garage_color border: #black;
    }
}