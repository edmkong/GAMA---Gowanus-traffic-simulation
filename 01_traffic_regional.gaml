/**
* Model 01 — Regional Traffic & Parking Pressure
* ================================================
* Gowanus Urban Design Strategy Studio
*
* INSIGHT:
*   Gowanus BID operates at ~94% parking occupancy today (midday peak).
*   The 2021 NYC Gowanus Rezoning projects 8,000+ new residential units by 2034,
*   substantially increasing vehicle arrivals from adjacent corridors
*   (Carroll Gardens to the north, Red Hook to the south, Park Slope to the east).
*
* TRANSFORMATION:
*   2029 — Smart parking management: real-time guidance app + demand-based pricing
*   2034 — Complete Streets redesign: protected bike lanes on Bond/Nevins/Smith St,
*           reduced on-street parking supply, improved G-train service
*
* PREDICTION (2-axis framework):
*   Axis 1 — Time:         2024 → 2029 → 2034
*   Axis 2 — Intervention: No Action ↔ Managed
*
*   Without action → occupancy exceeds 130% by 2034; failed parking searches
*   triple; congestion spills into surrounding BIDs.
*   With Smart Parking (2029) → failed searches drop 40%; occupancy <95%.
*   With Complete Streets (2034) → 25% fewer car trips; sustainable at ~90%.
*/

model regional_traffic_parking

global {
	float step <- 10 #s;

	// ── GIS Layers ──────────────────────────────────────────────────────────
	file shapefile_bid       <- shape_file("../includes/BID_vector.shp");
	file shapefile_buildings <- shape_file("../includes/bid_buildings.shp");
	file shapefile_water     <- shape_file("../includes/bid_water.shp");
	file shapefile_roads     <- shape_file("../includes/Brooklyn.shp");
	file shapefile_parking_spots <- shape_file("../includes/gowanus_final_spots.shp");

	geometry shape   <- envelope(shapefile_roads);
	geometry bid_geom;

	graph road_network;
	map<road, float> move_weights;

	// ── Scenario Selector ───────────────────────────────────────────────────
	// 2024_baseline | 2029_no_action | 2029_smart_parking
	// 2034_no_action | 2034_complete_streets
	string scenario_name <- "2024_baseline";

	// ── Supply ──────────────────────────────────────────────────────────────
	int   proxy_base_parking_spaces <- 220;
	int   nb_parking_spaces         <- 220;
	float supply_ratio              <- 1.0;

	// ── Demand (calibrated per scenario) ────────────────────────────────────
	float initial_occupied_rate  <- 0.936;
	float deficit_ratio          <- 0.0;
	int   initial_searching_cars <- 15;
	float arrival_prob_per_step  <- 0.15;
	int   max_arrivals_per_event <- 3;

	// ── Behavior ────────────────────────────────────────────────────────────
	float arrival_threshold     <- 15.0;
	float entry_exit_buffer     <- 1000.0;
	int   min_dwell_steps       <- 100;   // ~17 min at 10 s/step
	int   max_dwell_steps       <- 400;   // ~67 min at 10 s/step
	float leave_prob_per_step   <- 0.0003; // small early-departure chance
	int   exit_duration_steps   <- 40;
	int   max_search_steps      <- 120;
	float give_up_prob_per_step <- 0.003;

	// ── Intervention flags ──────────────────────────────────────────────────
	bool  smart_parking_enabled <- false;
	float smart_parking_boost   <- 0.0;    // fraction reduction in search time

	// ── Metrics ─────────────────────────────────────────────────────────────
	int   occupied_spaces_count      <- 0;
	float occupied_spaces_ratio      <- 0.0;
	int   entered_bid_count          <- 0;
	int   left_without_parking_count <- 0;
	int   left_after_parking_count   <- 0;
	int   failed_search_count        <- 0;
	int   failed_search_recent       <- 0;   // failures accumulated in current window
	int   failed_search_timer        <- 0;   // step counter for rolling window
	float failed_search_rate         <- 0.0; // failures per 50-step window
	int   successful_parks_count     <- 0;
	int   exited_count               <- 0;
	float mean_last_search_steps     <- 0.0;
	float mean_total_search_steps    <- 0.0;
	float mean_current_search_steps  <- 0.0;
	float congestion_index           <- 0.0;

	init {
		do apply_scenario_parameters;

		create bid_boundary from: shapefile_bid;
		bid_geom <- one_of(bid_boundary).shape;

		create water_body from: shapefile_water;
		create building from: shapefile_buildings with: [type::string(read("type"))];
		create road from: shapefile_roads with: [fclass::string(read("fclass"))];

		road_network <- as_edge_graph(road where (each.drivable));
		move_weights <- (road where (each.drivable)) as_map
			(each :: (each.shape.perimeter / each.speed_rate));

		create parking_space from: shapefile_parking_spots with: [
			heading::float(read("heading"))
		];

		int total_spots <- length(parking_space);
		proxy_base_parking_spaces <- total_spots;
		nb_parking_spaces <- max([1, int(total_spots * supply_ratio)]);
		initial_searching_cars <- (deficit_ratio <= 0.0) ?
			6 : max([6, int(nb_parking_spaces * deficit_ratio)]);

		ask parking_space { active <- false; occupied <- false; occupant_id <- -1; }
		list<parking_space> shuffled_spots <- shuffle(parking_space);
		loop i from: 0 to: (length(shuffled_spots) - 1) {
			parking_space s <- (shuffled_spots at i);
			if s != nil {
				s.active <- (i < nb_parking_spaces);
			}
		}

		int n_parked <- min([length(parking_space where (each.active)),
			int(length(parking_space where (each.active)) * initial_occupied_rate)]);
		int eff_max <- smart_parking_enabled ?
			int(max_search_steps * (1.0 - smart_parking_boost)) : max_search_steps;

		create car number: n_parked {
			parking_space s <- one_of(parking_space where (each.active and (not each.occupied)));
			if s != nil {
				location             <- s.location;
				assigned_spot        <- s;
				state                <- "parked";
				ever_parked          <- true;
				has_been_in_bid      <- true;
				inside_bid_prev      <- true;
				dwell_steps          <- min_dwell_steps + int(rnd(max_dwell_steps - min_dwell_steps));
				effective_max_search <- eff_max;
				s.occupied           <- true;
				s.occupant_id        <- index;
			}
		}

		create car number: initial_searching_cars {
			road r <- one_of(road where (each.entry_candidate));
			if r != nil {
				location             <- any_location_in(r);
				state                <- "searching";
				inside_bid_prev      <- false;
				has_been_in_bid      <- false;
				effective_max_search <- eff_max;
			}
		}

		do update_metrics;
	}

	action apply_scenario_parameters {
		// ── 2024 Baseline: parking study data, ~94% occupancy ──
		if scenario_name = "2024_baseline" {
			// ~94% occ; balanced: ~0.9 arrivals/step ≈ departure rate from 250-step mean dwell
			supply_ratio           <- 1.0;
			initial_occupied_rate  <- 0.936;
			deficit_ratio          <- 0.0;
			arrival_prob_per_step  <- 0.60;
			max_arrivals_per_event <- 2;
			leave_prob_per_step    <- 0.0003;
			smart_parking_enabled  <- false;
			smart_parking_boost    <- 0.0;
		}
		// ── 2029 No Action: ~4,000 new units completed, +30% demand ──
		else if scenario_name = "2029_no_action" {
			supply_ratio           <- 1.0;
			initial_occupied_rate  <- 0.980;
			deficit_ratio          <- 0.08;
			arrival_prob_per_step  <- 0.72;
			max_arrivals_per_event <- 3;
			leave_prob_per_step    <- 0.0003;
			smart_parking_enabled  <- false;
			smart_parking_boost    <- 0.0;
		}
		// ── 2029 Smart Parking: app-guided + demand pricing ──
		// Same demand; 45% faster spot-finding; higher turnover (demand pricing shortens stays)
		else if scenario_name = "2029_smart_parking" {
			supply_ratio           <- 1.0;
			initial_occupied_rate  <- 0.920;
			deficit_ratio          <- 0.0;
			arrival_prob_per_step  <- 0.72;
			max_arrivals_per_event <- 3;
			leave_prob_per_step    <- 0.0010;
			smart_parking_enabled  <- true;
			smart_parking_boost    <- 0.45;
		}
		// ── 2034 No Action: full 8,000-unit buildout, severe deficit ──
		// Many more arrivals than supply can handle → searching cars pile up
		else if scenario_name = "2034_no_action" {
			supply_ratio           <- 1.0;
			initial_occupied_rate  <- 0.995;
			deficit_ratio          <- 0.28;
			arrival_prob_per_step  <- 0.90;
			max_arrivals_per_event <- 5;
			leave_prob_per_step    <- 0.0002;
			smart_parking_enabled  <- false;
			smart_parking_boost    <- 0.0;
		}
		// ── 2034 Complete Streets: 25% fewer car trips; smart parking;
		//    some supply converted to bike infrastructure ──
		else if scenario_name = "2034_complete_streets" {
			supply_ratio           <- 0.85;
			initial_occupied_rate  <- 0.900;
			deficit_ratio          <- 0.0;
			arrival_prob_per_step  <- 0.65;
			max_arrivals_per_event <- 3;
			leave_prob_per_step    <- 0.0010;
			smart_parking_enabled  <- true;
			smart_parking_boost    <- 0.55;
		}
		else {
			supply_ratio           <- 1.0;
			initial_occupied_rate  <- 0.936;
			deficit_ratio          <- 0.0;
			arrival_prob_per_step  <- 0.60;
			max_arrivals_per_event <- 2;
			leave_prob_per_step    <- 0.0003;
			smart_parking_enabled  <- false;
			smart_parking_boost    <- 0.0;
		}

		nb_parking_spaces <- max([1, int(proxy_base_parking_spaces * supply_ratio)]);
		initial_searching_cars <- (deficit_ratio <= 0.0) ?
			6 : max([6, int(nb_parking_spaces * deficit_ratio)]);
	}

	reflex update_weights {
		move_weights <- (road where (each.drivable)) as_map
			(each :: (each.shape.perimeter / each.speed_rate));
	}

	reflex spawn_arrivals when: flip(arrival_prob_per_step) {
		int n <- 1 + rnd(max_arrivals_per_event - 1);
		int eff <- smart_parking_enabled ?
			int(max_search_steps * (1.0 - smart_parking_boost)) : max_search_steps;
		create car number: n {
			road r <- one_of(road where (each.entry_candidate));
			if r != nil {
				location             <- any_location_in(r);
				state                <- "searching";
				inside_bid_prev      <- false;
				has_been_in_bid      <- false;
				effective_max_search <- eff;
			}
		}
	}

	action update_metrics {
		list<car> parked_once   <- car where (each.ever_parked);
		list<car> searching_now <- car where (each.state = "searching");

		occupied_spaces_count <- length(parking_space where (each.active and each.occupied));
		occupied_spaces_ratio <- occupied_spaces_count /
			max([1.0, float(length(parking_space where (each.active)))]);
		successful_parks_count <- length(car where (each.ever_parked));

		mean_last_search_steps   <- empty(parked_once) ? 0.0 :
			mean(parked_once collect each.last_search_steps);
		mean_total_search_steps  <- empty(parked_once) ? 0.0 :
			mean(parked_once collect each.total_search_steps);
		mean_current_search_steps <- empty(searching_now) ? 0.0 :
			mean(searching_now collect each.search_steps_current);

		// Congestion: V/C ratio — searching cars inside BID vs total parking supply
		// Capped at 1.0; rises as more cars circle looking for spots
		int searching_in_bid <- length(car where (
			(each.state = "searching") and
			(each.location intersects bid_geom)
		));
		congestion_index <- min([1.0,
			float(searching_in_bid) / float(max([1, nb_parking_spaces]))]);

		// Rolling failed-search rate (resets every 50 steps)
		failed_search_timer <- failed_search_timer + 1;
		if failed_search_timer >= 50 {
			failed_search_rate   <- float(failed_search_recent);
			failed_search_recent <- 0;
			failed_search_timer  <- 0;
		}
	}

	reflex refresh_metrics { do update_metrics; }
}

// ── Species ─────────────────────────────────────────────────────────────────

species bid_boundary {
	aspect default { draw shape color: rgb(0,0,0,0) border: #red width: 3; }
}

species water_body {
	aspect default { draw shape color: rgb(100,170,255) border: rgb(60,120,220); }
}

species building {
	string type <- "unknown";
	aspect default {
		rgb c <- (type = "garage") ? rgb(0,180,110) : rgb(200,200,200);
		draw shape color: c border: rgb(130,130,130);
	}
}

species road {
	string fclass <- "unknown";

	bool drivable <- ((fclass = "primary") or (fclass = "secondary") or
		(fclass = "tertiary") or (fclass = "residential") or
		(fclass = "residentioal") or (fclass = "service"));

	bool in_bid <- (shape intersects bid_geom);

	bool parking_candidate <- (in_bid and
		((fclass = "secondary") or (fclass = "tertiary") or
		 (fclass = "residential") or (fclass = "residentioal") or
		 (fclass = "service")));

	bool entry_candidate <- (drivable and (not in_bid) and
		((shape distance_to bid_geom) < entry_exit_buffer));

	bool exit_candidate <- entry_candidate;

	float capacity <- max([1.0, shape.perimeter / 25.0]);

	int nb_cars_here <- 0 update:
		length(car where (
			((each.state = "searching") or (each.state = "exiting")) and
			((each distance_to self) < 8)));

	float speed_rate <- 1.0 update:
		max([0.2, exp(-nb_cars_here / capacity)]);

	aspect default {
		if in_bid and drivable {
			// Green (free) → Red (congested) heat map inside BID
			draw shape color: rgb(int(220 * (1.0 - speed_rate)), int(200 * speed_rate), 0) width: 2;
		} else if drivable and (fclass = "primary" or fclass = "secondary") {
			draw shape color: rgb(90, 90, 90) width: 2;
		} else if drivable {
			draw shape color: rgb(140, 140, 140) width: 1;
		} else {
			draw shape color: rgb(200, 200, 200) width: 1;
		}
	}
}

species parking_space {
	float heading     <- 0.0;
	bool active       <- true;
	bool occupied    <- false;
	int  occupant_id <- -1;

	aspect default {
		if active {
			draw circle(4) color: (occupied ? #red : #lime);
		}
	}
}

species car skills: [moving] {
	parking_space assigned_spot <- nil;
	point         exit_target   <- nil;
	string        state         <- "searching";  // searching | parked | exiting

	int dwell_steps          <- 0;
	int exit_timer           <- 0;
	int search_steps_current <- 0;
	int last_search_steps    <- 0;
	int total_search_steps   <- 0;
	// Set by global init based on smart_parking_enabled and smart_parking_boost
	int effective_max_search <- 240;

	bool ever_parked     <- false;
	bool has_been_in_bid <- false;
	bool inside_bid_prev <- false;

	float speed           <- 15 #km/#h;
	float searching_speed <- 15 #km/#h;
	float exiting_speed   <- 25 #km/#h;

	aspect default {
		if state = "parked" {
			draw circle(5) color: #yellow border: rgb(80,80,0);
		} else if state = "exiting" {
			draw circle(6) color: rgb(180,0,200) border: #white;
		} else if (location intersects bid_geom) {
			draw circle(6) color: rgb(0,150,255) border: #white;
		} else {
			draw circle(6) color: rgb(255,140,0) border: #white;
		}
	}

	reflex track_bid_crossing {
		bool now_inside <- (location intersects bid_geom);
		if (not inside_bid_prev) and now_inside {
			entered_bid_count <- entered_bid_count + 1;
			has_been_in_bid   <- true;
		}
		if inside_bid_prev and (not now_inside) and (state = "exiting") {
			do finalize_exit;
		}
		inside_bid_prev <- now_inside;
	}

	reflex count_search_time when: (state = "searching") {
		search_steps_current <- search_steps_current + 1;
	}

	reflex choose_parking when: (state = "searching") and (assigned_spot = nil) {
		list<parking_space> free <- parking_space where (each.active and (not each.occupied));
		if not empty(free) {
			// Smart parking picks nearest free spot; unmanaged picks randomly
			assigned_spot <- smart_parking_enabled ?
				(free with_min_of (each distance_to location)) : one_of(free);
			assigned_spot.occupied    <- true;
			assigned_spot.occupant_id <- index;
		}
	}

	reflex give_up when: (state = "searching") {
		if (search_steps_current >= effective_max_search) or flip(give_up_prob_per_step) {
			if assigned_spot != nil {
				assigned_spot.occupied    <- false;
				assigned_spot.occupant_id <- -1;
				assigned_spot             <- nil;
			}
			failed_search_count  <- failed_search_count + 1;
			failed_search_recent <- failed_search_recent + 1;
			do start_exit;
		}
	}

	reflex move_to_parking when: (state = "searching") and (assigned_spot != nil) {
		speed <- searching_speed;
		do goto target: assigned_spot.location on: road_network move_weights: move_weights;
		if (location distance_to assigned_spot.location) < arrival_threshold {
			state                <- "parked";
			dwell_steps          <- min_dwell_steps + rnd(max_dwell_steps - min_dwell_steps);
			last_search_steps    <- search_steps_current;
			total_search_steps   <- total_search_steps + search_steps_current;
			search_steps_current <- 0;
			ever_parked          <- true;
		}
	}

	reflex stay_parked when: (state = "parked") {
		dwell_steps <- dwell_steps - 1;
		if flip(leave_prob_per_step) or (dwell_steps <= 0) {
			if assigned_spot != nil {
				assigned_spot.occupied    <- false;
				assigned_spot.occupant_id <- -1;
				assigned_spot             <- nil;
			}
			do start_exit;
		}
	}

	action start_exit {
		state      <- "exiting";
		exit_timer <- exit_duration_steps;
		list<road> exits <- road where (each.exit_candidate);
		if not empty(exits) { exit_target <- any_location_in(one_of(exits)); }
	}

	// Timer always counts down — car dies after exit_duration_steps regardless of path
	reflex exit_countdown when: state = "exiting" {
		exit_timer <- exit_timer - 1;
		if exit_timer <= 0 {
			do finalize_exit;
		} else if exit_target != nil {
			speed <- exiting_speed;
			do goto target: exit_target on: road_network move_weights: move_weights;
		}
	}

	action finalize_exit {
		if has_been_in_bid {
			if ever_parked { left_after_parking_count  <- left_after_parking_count + 1; }
			else           { left_without_parking_count <- left_without_parking_count + 1; }
		}
		exited_count <- exited_count + 1;
		do die;
	}
}

// ── Experiment ──────────────────────────────────────────────────────────────

experiment traffic_scenarios type: gui {
	parameter "Scenario" var: scenario_name category: "Scenario"
		among: ["2024_baseline","2029_no_action","2029_smart_parking",
		        "2034_no_action","2034_complete_streets"];
	parameter "Arrival prob / step"    var: arrival_prob_per_step      category: "Demand";
	parameter "Max arrivals / event"   var: max_arrivals_per_event     category: "Demand";
	parameter "Leave prob / step"      var: leave_prob_per_step        category: "Behavior";
	parameter "Smart parking active"   var: smart_parking_enabled      category: "Intervention";
	parameter "Smart parking boost"    var: smart_parking_boost        category: "Intervention";

	output {
		monitor "Scenario"              value: scenario_name;
		monitor "Parking Supply"        value: nb_parking_spaces;
		monitor "Occupied Spaces"       value: occupied_spaces_count;
		monitor "Occupancy %"           value: occupied_spaces_ratio * 100;
		monitor "Cars Searching"        value: length(car where (each.state = "searching"));
		monitor "Cars Parked"           value: length(car where (each.state = "parked"));
		monitor "Failed Searches (total)" value: failed_search_count;
		monitor "Failed/50-step window"   value: failed_search_rate;
		monitor "Left Without Parking"  value: left_without_parking_count;
		monitor "Congestion Index (0-1)" value: congestion_index;
		monitor "Avg Search Time (steps)" value: mean_current_search_steps;

		display "Gowanus BID — Traffic & Parking" type: 2d background: #white {
			species water_body;
			species building;
			species road;
			species bid_boundary;
			species parking_space;
			species car;
		}

		display "Prediction Charts" type: 2d {
			chart "Parking Occupancy (%)" type: series
				size: {1.0, 0.34} position: {0.0, 0.0} {
				data "Occupancy %" value: occupied_spaces_ratio * 100
					color: #firebrick style: line;
			}
			chart "Search Pressure" type: series
				size: {1.0, 0.33} position: {0.0, 0.34} {
				data "Searching cars"             value: length(car where (each.state = "searching"))
					color: #steelblue style: line;
				data "Failed searches / 50 steps" value: failed_search_rate
					color: #darkorange style: line;
			}
			chart "Congestion Index" type: series
				size: {1.0, 0.33} position: {0.0, 0.67} {
				data "Congestion (0=free, 1=gridlock)"
					value: congestion_index color: #darkred style: line;
			}
		}
	}
}
