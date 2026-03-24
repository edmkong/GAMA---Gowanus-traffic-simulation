model parking_mvp_boundary_flow

global {
	// =========================
	// Time / movement
	// =========================
	float step <- 20 #s;
	float arrival_threshold <- 0.00008;

	// =========================
	// GIS
	// =========================
	file shapefile_roads <- shape_file("../includes/Brooklyn.shp");
	file shapefile_bid <- shape_file("../includes/BID_vector.shp");
	file shapefile_parking_spots <- shape_file("../includes/gowanus_final_spots.shp");
	file shapefile_water <- shape_file("../includes/bid_water.shp");
	file shapefile_public_parking <- shape_file("../includes/public_parking_facilities.shp");

	geometry shape <- envelope(shapefile_roads);
	geometry bid_geom <- nil;

	// BID-centered traffic cordon
	geometry outer_cordon <- nil;
	geometry inner_cordon <- nil;

	graph road_network;

	// bounds of the outer cordon
	float cordon_min_x <- 0.0;
	float cordon_max_x <- 0.0;
	float cordon_min_y <- 0.0;
	float cordon_max_y <- 0.0;

	// bounds of the Brooklyn area envelope (spawn/exit boundary points)
	float area_min_x <- 0.0;
	float area_max_x <- 0.0;
	float area_min_y <- 0.0;
	float area_max_y <- 0.0;
	float area_boundary_buffer <- 0.0008;

	// =========================
	// Gateway selection
	// =========================
	float outer_cordon_margin <- 0.005;
	float inner_cordon_margin <- 0.003;
	float gateway_min_length <- 0.0015;
	float min_gateway_trip_separation <- 0.0025;
	float min_edge_target_distance <- 0.0020;

	list<road> strong_gateway_roads <- [];
	list<road> fallback_gateway_roads <- [];
	list<road> bid_roads <- [];
	list<road> boundary_roads <- [];

	// =========================
	// Traffic controls
	// =========================
	int initial_cars <- 120;
	// Adjusted for 20s step to keep approximately the same per-minute arrival flow as 0.18 at 10s.
	float spawn_prob_per_step <- 0.3276;
	int max_new_cars_per_spawn <- 4;
	float exit_prob_at_gateway <- 0.35;

	// =========================
	// Parking controls
	// =========================
	string scenario_mode <- "mixed_0.1_garage_0.1_street";
	float initial_parking_occupied_rate <- 0.9;
	float garage_destination_prob <- 0.1;
	float street_parking_destination_prob <- 0.1;
	float street_first_destination_prob <- 0.2;
	float garage_first_destination_prob <- 0.2;
	int street_attempts_before_garage <- 10;
	int max_parking_search_processes <- 10;

	// Parking dwell-time model (step = 20s):
	// short-term ~30 min, night-term ~7 h, long-term ~1 week
	int short_term_mean_steps <- 90;
	int night_term_mean_steps <- 1260;
	int long_term_mean_steps <- 30240;

	// Share of parked cars by profile
	float parking_profile_short_share <- 0.55;
	float parking_profile_night_share <- 0.30;
	// long-term share is the remainder

	// =========================
	// Recovery
	// =========================
	float min_progress_distance <- 0.000005;
	int max_stagnant_steps <- 4;
	int max_no_progress_steps <- 4;
	int max_backtracks_per_car <- 4;
	int max_stagnant_steps_while_backtracking <- 6;

	// =========================
	// Metrics
	// =========================
	int cars_spawned_count <- 0;
	int cars_exited_count <- 0;
	int cars_continued_count <- 0;
	int cars_backtracked_count <- 0;
	int cars_respawned_count <- 0;

	int bid_entries_count <- 0;
	int bid_exits_count <- 0;
	int cars_ever_entered_bid_count <- 0;

	int cars_started_parking_search_count <- 0;
	int cars_failed_parking_and_left_count <- 0;
	int cars_parked_successfully_count <- 0;
	int cars_assigned_to_garage_count <- 0;
	int cars_failed_garage_and_left_count <- 0;
	int cars_parked_in_garage_count <- 0;
	int no_empty_spot_check_count <- 0;
	int occupied_spot_arrival_count <- 0;
	int total_parking_spot_visits_count <- 0;

	init {
		create bid_boundary from: shapefile_bid;
		if not empty(bid_boundary) {
			bid_geom <- one_of(bid_boundary).shape;
		}

		create water_body from: shapefile_water;

		create road from: shapefile_roads with: [
			fclass::string(read("fclass")),
			road_name::string(read("name")),
			oneway::string(read("oneway")),
			maxspeed::float(read("maxspeed"))
		];

		list<float> area_xs <- shape.points collect each.x;
		list<float> area_ys <- shape.points collect each.y;
		area_min_x <- min(area_xs);
		area_max_x <- max(area_xs);
		area_min_y <- min(area_ys);
		area_max_y <- max(area_ys);

		road_network <- as_edge_graph(road where (each.navigable_for_agents));

		if bid_geom != nil {
			outer_cordon <- envelope(bid_geom) enlarged_by outer_cordon_margin;
			inner_cordon <- envelope(bid_geom) enlarged_by inner_cordon_margin;

			list<float> xs <- outer_cordon.points collect each.x;
			list<float> ys <- outer_cordon.points collect each.y;

			cordon_min_x <- min(xs);
			cordon_max_x <- max(xs);
			cordon_min_y <- min(ys);
			cordon_max_y <- max(ys);
		}

		strong_gateway_roads <- road where (each.strong_gateway_candidate);
		fallback_gateway_roads <- road where (each.fallback_gateway_candidate);
		bid_roads <- road where (each.drivable and each.in_bid);
		boundary_roads <- road where (each.navigable_for_agents and each.near_area_boundary);
		if empty(boundary_roads) {
			boundary_roads <- road where (each.navigable_for_agents);
		}
		if empty(boundary_roads) {
			boundary_roads <- road where (each.drivable);
		}

		// =========================
		// Parking spots
		// =========================
		create parking_space from: shapefile_parking_spots with: [
			heading::float(read("heading"))
		];

		ask parking_space {
			occupied <- flip(initial_parking_occupied_rate);
		}

		create public_parking_facility from: shapefile_public_parking with: [
			facility_name::string(read("name")),
			licensed_capacity::int(float(read("lic_cap"))),
			midday_available::int(float(read("mid_avail")))
		];
		ask public_parking_facility {
			current_occupied <- min([licensed_capacity, max([0, midday_occupied])]);
		}

		// Initial flowing cars
		create car number: initial_cars {
			do spawn_on_random_road;
			do choose_initial_destination;
			cars_spawned_count <- cars_spawned_count + 1;
		}
	}

	reflex spawn_new_cars when: flip(spawn_prob_per_step) {
		int nb_new <- 1 + int(rnd(max_new_cars_per_spawn));

		create car number: nb_new {
			do spawn_on_area_boundary;
			do choose_initial_destination;

			cars_spawned_count <- cars_spawned_count + 1;
		}
	}
}

species bid_boundary {
	aspect debug_geom {
		draw shape color: rgb(255,0,0,45) border: #red width: 5;
	}
}

species water_body {
	aspect default {
		draw shape color: rgb(70,130,180,120) border: rgb(70,130,180);
	}
}

species road {
	string fclass <- "unknown";
	string road_name <- "";
	string oneway <- "";
	float maxspeed <- 0.0;

	bool drivable <- (
		(fclass = "motorway") or
		(fclass = "motorway_link") or
		(fclass = "trunk") or
		(fclass = "trunk_link") or
		(fclass = "primary") or
		(fclass = "primary_link") or
		(fclass = "secondary") or
		(fclass = "secondary_link") or
		(fclass = "tertiary") or
		(fclass = "tertiary_link") or
		(fclass = "residential") or
		(fclass = "residentioal") or
		(fclass = "service") or
		(fclass = "unclassified")
	);

	// Avoid tiny local/service dead-end traps for moving cars.
	bool navigable_for_agents <- (
		drivable and
		(fclass != "service") and
		(fclass != "unclassified") and
		(fclass != "residentioal")
	);

	bool in_bid <- (
		(bid_geom != nil) and
		(location intersects bid_geom)
	);

	bool in_outer_cordon <- (
		(outer_cordon != nil) and
		(location intersects outer_cordon)
	);

	bool in_inner_cordon <- (
		(inner_cordon != nil) and
		(location intersects inner_cordon)
	);

	bool in_gateway_ring <- (
		in_outer_cordon and
		(not in_inner_cordon)
	);

	bool high_class_gateway <- (
		(fclass = "motorway") or
		(fclass = "motorway_link") or
		(fclass = "trunk") or
		(fclass = "trunk_link") or
		(fclass = "primary") or
		(fclass = "primary_link") or
		(fclass = "secondary") or
		(fclass = "secondary_link")
	);

	bool fallback_class_gateway <- (
		high_class_gateway or
		(fclass = "tertiary") or
		(fclass = "tertiary_link")
	);

	bool named_road <- (
		(road_name != nil) and
		(road_name != "")
	);

	bool long_enough <- (
		shape.perimeter >= gateway_min_length
	);

	string gateway_side <- (
		(location.x <= (cordon_min_x + 0.0008)) ? "west" :
		((location.x >= (cordon_max_x - 0.0008)) ? "east" :
		((location.y <= (cordon_min_y + 0.0008)) ? "south" : "north"))
	);

	bool strong_gateway_candidate <- (
		drivable and
		in_gateway_ring and
		high_class_gateway and
		named_road and
		long_enough
	);

	bool fallback_gateway_candidate <- (
		drivable and
		in_gateway_ring and
		fallback_class_gateway and
		long_enough
	);

	bool near_area_boundary <- (
		(location.x <= (area_min_x + area_boundary_buffer)) or
		(location.x >= (area_max_x - area_boundary_buffer)) or
		(location.y <= (area_min_y + area_boundary_buffer)) or
		(location.y >= (area_max_y - area_boundary_buffer))
	);

	aspect default {
		if strong_gateway_candidate {
			draw shape color: rgb(200,60,60);
		} else if fallback_gateway_candidate {
			draw shape color: rgb(220,160,60);
		} else if drivable {
			draw shape color: rgb(75,75,75);
		} else {
			draw shape color: rgb(190,190,190);
		}
	}
}

species parking_space {
	float heading <- 0.0;

	bool occupied <- false;
	int visited_count <- 0;

	aspect default {
		draw square(8) color: #yellow border: #black rotate: heading;
	}
}

species public_parking_facility {
	string facility_name <- "";
	int licensed_capacity <- 0;
	int midday_available <- 0;
	int midday_occupied <- max([0, licensed_capacity - midday_available]);
	int current_occupied <- 0;
	int current_available <- max([0, licensed_capacity - current_occupied]);
	bool full <- (current_occupied >= licensed_capacity) and (licensed_capacity > 0);

	aspect default {
		draw rectangle(50,30) color: #green border: #black;
	}
}

species car skills: [moving] {
	point target <- nil;
	point edge_target <- nil;
	parking_space assigned_spot <- nil;
	public_parking_facility assigned_garage <- nil;
	int last_spot_index <- -1;

	// moving | parked
	string phase <- "moving";
	// parking | garage | edge
	string destination_type <- "edge";

	bool inside_bid_prev <- false;
	bool ever_entered_bid <- false;
	bool ever_parked <- false;

	int parking_search_processes <- 0;
	int stagnant_steps <- 0;
	int no_progress_steps <- 0;
	float previous_distance_to_target <- -1.0;
	string parking_profile <- "short_term";
	int parked_steps <- 0;

	float speed <- 25 #km / #h;

	action reset_progress_trackers {
		stagnant_steps <- 0;
		no_progress_steps <- 0;
		previous_distance_to_target <- -1.0;
	}

	action assign_parking_profile {
		float r <- rnd(1.0);
		if r < parking_profile_short_share {
			parking_profile <- "short_term";
		} else if r < (parking_profile_short_share + parking_profile_night_share) {
			parking_profile <- "night_term";
		} else {
			parking_profile <- "long_term";
		}
	}

	action choose_random_boundary_target {
		list<road> candidates <- boundary_roads;

		candidates <- candidates where (
			((current_edge = nil) or (each != current_edge)) and
			((each.location distance_to location) >= min_edge_target_distance)
		);

		if empty(candidates) {
			candidates <- boundary_roads where ((current_edge = nil) or (each != current_edge));
		}
		if empty(candidates) {
			candidates <- boundary_roads;
		}
		if empty(candidates) {
			candidates <- road where (each.navigable_for_agents and ((current_edge = nil) or (each != current_edge)));
		}
		if empty(candidates) {
			candidates <- road where (each.navigable_for_agents);
		}
		if empty(candidates) {
			candidates <- road where (each.drivable);
		}

		road target_edge_road <- one_of(candidates);

		if target_edge_road != nil {
			edge_target <- any_location_in(target_edge_road);
			target <- edge_target;
			do reset_progress_trackers;
		} else {
			edge_target <- nil;
			target <- nil;
		}
	}

	action switch_to_edge_mode {
		destination_type <- "edge";
		target <- nil;
		assigned_spot <- nil;
		assigned_garage <- nil;
		edge_target <- nil;
		do reset_progress_trackers;
		do choose_random_boundary_target;
	}

	action spawn_on_area_boundary {
		road start_road <- one_of(boundary_roads);
		if start_road = nil {
			start_road <- one_of(road where (each.navigable_for_agents));
		}
		if start_road = nil {
			start_road <- one_of(road where (each.drivable));
		}
		if start_road != nil {
			location <- any_location_in(start_road);
		}

		phase <- "moving";
		target <- nil;
		edge_target <- nil;
		assigned_spot <- nil;
		assigned_garage <- nil;
		last_spot_index <- -1;
		destination_type <- "edge";
		parking_search_processes <- 0;
		do reset_progress_trackers;
		parked_steps <- 0;

		inside_bid_prev <- (bid_geom != nil) and (location intersects bid_geom);
		ever_entered_bid <- inside_bid_prev;
	}

	action spawn_on_random_road {
		road start_road <- one_of(road where (each.navigable_for_agents));
		if start_road = nil {
			start_road <- one_of(road where (each.drivable));
		}
		if start_road != nil {
			location <- any_location_in(start_road);
		}

		phase <- "moving";
		target <- nil;
		edge_target <- nil;
		assigned_spot <- nil;
		assigned_garage <- nil;
		last_spot_index <- -1;
		destination_type <- "edge";
		parking_search_processes <- 0;
		do reset_progress_trackers;
		parked_steps <- 0;

		inside_bid_prev <- (bid_geom != nil) and (location intersects bid_geom);
		ever_entered_bid <- inside_bid_prev;
	}

	action choose_next_parking_search_target {
		list<parking_space> free_all <- parking_space where (not each.occupied);
		list<parking_space> occ_all <- parking_space where (each.occupied);
		list<parking_space> free_candidates <- free_all where (each.index != last_spot_index);
		list<parking_space> occ_candidates <- occ_all where (each.index != last_spot_index);

		if empty(free_candidates) and (not empty(free_all)) { free_candidates <- free_all; }
		if empty(occ_candidates) and (not empty(occ_all)) { occ_candidates <- occ_all; }

		if not empty(free_candidates) {
			assigned_spot <- one_of(free_candidates);
		} else if not empty(occ_candidates) {
			assigned_spot <- one_of(occ_candidates);
		} else {
			assigned_spot <- nil;
			target <- nil;
		}

		if assigned_spot != nil {
			last_spot_index <- assigned_spot.index;
			assigned_garage <- nil;
			edge_target <- nil;

			list<road> drivable_roads <- road where (each.navigable_for_agents);
			if empty(drivable_roads) {
				drivable_roads <- road where (each.drivable);
			}
			if not empty(drivable_roads) {
				road approach_road <- drivable_roads with_min_of (each.location distance_to assigned_spot.location);
				if approach_road != nil {
					target <- any_location_in(approach_road);
				} else {
					target <- assigned_spot.location;
				}
			} else {
				target <- assigned_spot.location;
			}

			do reset_progress_trackers;
		}
	}

	action choose_garage_target_or_leave {
		list<public_parking_facility> free_garages <- public_parking_facility where (each.current_occupied < each.licensed_capacity);

		if empty(free_garages) {
			cars_failed_garage_and_left_count <- cars_failed_garage_and_left_count + 1;
			if scenario_mode = "garage_0.2_then_street_if_full" {
				destination_type <- "parking";
				parking_search_processes <- 0;
				cars_started_parking_search_count <- cars_started_parking_search_count + 1;
				do choose_next_parking_search_target;
				if target = nil {
					do restart_parking_search_or_leave;
				}
			} else {
				do switch_to_edge_mode;
			}
		} else {
			assigned_garage <- one_of(free_garages);
			cars_assigned_to_garage_count <- cars_assigned_to_garage_count + 1;
			assigned_spot <- nil;
			edge_target <- nil;
			destination_type <- "garage";

			list<road> drivable_roads <- road where (each.navigable_for_agents);
			if empty(drivable_roads) {
				drivable_roads <- road where (each.drivable);
			}
			if not empty(drivable_roads) {
				road approach_road <- drivable_roads with_min_of (each.location distance_to assigned_garage.location);
				if approach_road != nil {
					target <- any_location_in(approach_road);
				} else {
					target <- assigned_garage.location;
				}
			} else {
				target <- assigned_garage.location;
			}

			do reset_progress_trackers;
		}
	}

	action restart_parking_search_or_leave {
		parking_search_processes <- parking_search_processes + 1;

		int street_attempt_limit <- max_parking_search_processes;
		if scenario_mode = "street_0.2_then_garage_after_10" {
			street_attempt_limit <- street_attempts_before_garage;
		}

		if parking_search_processes >= street_attempt_limit {
			if scenario_mode = "street_0.2_then_garage_after_10" {
				do choose_garage_target_or_leave;
			} else {
				cars_failed_parking_and_left_count <- cars_failed_parking_and_left_count + 1;
				do switch_to_edge_mode;
			}
		} else {
			do choose_next_parking_search_target;
		}
	}

	action snap_to_nearest_drivable_road {
		list<road> drivable_roads <- road where (each.navigable_for_agents);
		if empty(drivable_roads) {
			drivable_roads <- road where (each.drivable);
		}
		if not empty(drivable_roads) {
			road nearest_road <- drivable_roads with_min_of (each.location distance_to location);
			if nearest_road != nil {
				location <- any_location_in(nearest_road);
			}
		}
	}

	action choose_initial_destination {
		float r <- rnd(1.0);
		if scenario_mode = "street_0.2_then_garage_after_10" {
			if r < street_first_destination_prob {
				destination_type <- "parking";
				parking_search_processes <- 0;
				cars_started_parking_search_count <- cars_started_parking_search_count + 1;
				do choose_next_parking_search_target;
			} else {
				parking_search_processes <- 0;
				do switch_to_edge_mode;
			}
		} else if scenario_mode = "garage_0.2_then_street_if_full" {
			if r < garage_first_destination_prob {
				destination_type <- "garage";
				do choose_garage_target_or_leave;
			} else {
				parking_search_processes <- 0;
				do switch_to_edge_mode;
			}
		} else {
			if r < garage_destination_prob {
				destination_type <- "garage";
				do choose_garage_target_or_leave;
			} else if r < (garage_destination_prob + street_parking_destination_prob) {
				destination_type <- "parking";
				parking_search_processes <- 0;
				cars_started_parking_search_count <- cars_started_parking_search_count + 1;
				do choose_next_parking_search_target;
			} else {
				parking_search_processes <- 0;
				do switch_to_edge_mode;
			}
		}
	}

	reflex track_bid_crossing {
		bool now_inside <- (bid_geom != nil) and (location intersects bid_geom);

		if ((not inside_bid_prev) and now_inside) {
			bid_entries_count <- bid_entries_count + 1;
			if not ever_entered_bid {
				ever_entered_bid <- true;
				cars_ever_entered_bid_count <- cars_ever_entered_bid_count + 1;
			}
		}

		if (inside_bid_prev and (not now_inside)) {
			bid_exits_count <- bid_exits_count + 1;
		}

		inside_bid_prev <- now_inside;
	}

	reflex ensure_edge_target when: ((phase = "moving") and (destination_type = "edge") and (target = nil)) {
		do choose_random_boundary_target;
	}

	reflex enforce_destination_state when: (phase = "moving") {
		if destination_type = "parking" {
			edge_target <- nil;
			assigned_garage <- nil;
		} else if destination_type = "garage" {
			edge_target <- nil;
			assigned_spot <- nil;
		} else if destination_type = "edge" {
			assigned_spot <- nil;
			assigned_garage <- nil;
		}
	}

	reflex ensure_parking_target when: ((phase = "moving") and (destination_type = "parking") and (target = nil)) {
		do choose_next_parking_search_target;
		if target = nil {
			do restart_parking_search_or_leave;
		}
	}

	reflex ensure_garage_target when: ((phase = "moving") and (destination_type = "garage") and (target = nil)) {
		do choose_garage_target_or_leave;
	}

	reflex recover_if_off_graph when: ((phase = "moving") and (current_edge = nil)) {
		do snap_to_nearest_drivable_road;
		if destination_type = "parking" {
			do restart_parking_search_or_leave;
		} else if destination_type = "garage" {
			do choose_garage_target_or_leave;
		} else {
			do choose_random_boundary_target;
		}
	}

	reflex leave_parked_spot when: (phase = "parked") {
		parked_steps <- parked_steps + 1;

		float leave_prob <- 0.0;
		if parking_profile = "short_term" {
			leave_prob <- 1.0 / max([1.0, float(short_term_mean_steps)]);
		} else if parking_profile = "night_term" {
			leave_prob <- 1.0 / max([1.0, float(night_term_mean_steps)]);
		} else {
			leave_prob <- 1.0 / max([1.0, float(long_term_mean_steps)]);
		}

		if flip(leave_prob) {
			if assigned_spot != nil {
				assigned_spot.occupied <- false;
			}
			if assigned_garage != nil {
				assigned_garage.current_occupied <- max([0, assigned_garage.current_occupied - 1]);
			}
			phase <- "moving";
			assigned_spot <- nil;
			assigned_garage <- nil;
			parked_steps <- 0;
			parking_search_processes <- 0;
			do switch_to_edge_mode;
		}
	}

	reflex move when: ((phase = "moving") and (target != nil)) {
		point previous_location <- location;
		do goto target: target on: road_network recompute_path: false;
		float moved_distance <- location distance_to previous_location;

		if moved_distance <= min_progress_distance {
			stagnant_steps <- stagnant_steps + 1;
		} else {
			stagnant_steps <- 0;
		}

		bool reached_target <- (location distance_to target) <= arrival_threshold;
		bool reached_assigned_spot <- ((assigned_spot != nil) and ((location distance_to assigned_spot.location) <= (arrival_threshold * 2.0)));
		float current_distance_to_target <- location distance_to target;

		if previous_distance_to_target < 0.0 {
			previous_distance_to_target <- current_distance_to_target;
		} else {
			if current_distance_to_target >= (previous_distance_to_target - (arrival_threshold * 0.25)) {
				no_progress_steps <- no_progress_steps + 1;
			} else {
				no_progress_steps <- 0;
			}
			previous_distance_to_target <- current_distance_to_target;
		}

		if stagnant_steps >= max_stagnant_steps or (no_progress_steps >= max_no_progress_steps and (not reached_target) and (not reached_assigned_spot)) {
			if destination_type = "parking" {
				do restart_parking_search_or_leave;
			} else if destination_type = "garage" {
				do choose_garage_target_or_leave;
			} else {
				do choose_random_boundary_target;
			}
		} else if reached_target or reached_assigned_spot {
			if destination_type = "edge" {
				cars_exited_count <- cars_exited_count + 1;
				do die;
			} else if destination_type = "parking" {
					if (assigned_spot != nil) and (not assigned_spot.occupied) {
						location <- assigned_spot.location;
						assigned_spot.occupied <- true;
						assigned_spot.visited_count <- assigned_spot.visited_count + 1;
						total_parking_spot_visits_count <- total_parking_spot_visits_count + 1;
						do assign_parking_profile;
						phase <- "parked";
						ever_parked <- true;
						parked_steps <- 0;
						cars_parked_successfully_count <- cars_parked_successfully_count + 1;
					} else {
					occupied_spot_arrival_count <- occupied_spot_arrival_count + 1;
					do restart_parking_search_or_leave;
				}
				} else if destination_type = "garage" {
					if (assigned_garage != nil) and (assigned_garage.current_occupied < assigned_garage.licensed_capacity) {
						location <- assigned_garage.location;
						assigned_garage.current_occupied <- assigned_garage.current_occupied + 1;
						do assign_parking_profile;
						phase <- "parked";
						ever_parked <- true;
						parked_steps <- 0;
						cars_parked_in_garage_count <- cars_parked_in_garage_count + 1;
					} else {
						do choose_garage_target_or_leave;
					}
				}
			}
		}

	aspect default {
		draw circle(7) color: #blue;
	}
}

experiment boundary_flow type: gui {
	parameter "Initial cars" var: initial_cars category: "Traffic";
	parameter "Spawn probability per step" var: spawn_prob_per_step category: "Traffic";
	parameter "Max new cars per spawn" var: max_new_cars_per_spawn category: "Traffic";
	parameter "Scenario" var: scenario_mode category: "Scenario" among: ["mixed_0.1_garage_0.1_street","street_0.2_then_garage_after_10","garage_0.2_then_street_if_full"];
	parameter "Garage destination probability" var: garage_destination_prob category: "Destination Mix";
	parameter "Street parking destination probability" var: street_parking_destination_prob category: "Destination Mix";
	parameter "Street-first destination probability" var: street_first_destination_prob category: "Destination Mix";
	parameter "Garage-first destination probability" var: garage_first_destination_prob category: "Destination Mix";
	parameter "Street attempts before garage" var: street_attempts_before_garage category: "Scenario";
	parameter "Max parking search processes" var: max_parking_search_processes category: "Parking";
	parameter "Arrival threshold" var: arrival_threshold category: "Movement";

		output {
			monitor "Parking | Occupied Spots" value: length(parking_space where (each.occupied));
			monitor "Parking | Free Spots" value: length(parking_space where (not each.occupied));
			monitor "Parking | Occupancy %" value: round((100.0 * (length(parking_space where (each.occupied)) / max([1.0, float(length(parking_space))])) * 100.0) / 100.0);
			monitor "Scenario | Active" value: scenario_mode;
			monitor "Public Parking | Occupied / Total" value: (string(sum(public_parking_facility collect each.current_occupied)) + " / " + string(sum(public_parking_facility collect each.licensed_capacity)));
			monitor "Public Parking | Occupancy %" value: round((100.0 * (sum(public_parking_facility collect each.current_occupied) / max([1.0, float(sum(public_parking_facility collect each.licensed_capacity))])) * 100.0) / 100.0);
			monitor "Garage Flow | Cars Currently Going To Garage" value: length(car where ((each.phase = "moving") and (each.destination_type = "garage")));
			monitor "Garage Flow | Cars Assigned To Garage (Cumulative)" value: cars_assigned_to_garage_count;
			monitor "Garage Flow | Cars Parked In Garage (Cumulative)" value: cars_parked_in_garage_count;
			monitor "Garage Flow | Failed To Find Garage Then Left" value: cars_failed_garage_and_left_count;
			monitor "Traffic | Cars In BID Looking For Parking" value: length(car where ((bid_geom != nil) and (each.location intersects bid_geom) and (each.phase = "moving") and (each.destination_type = "parking")));
			monitor "Traffic | Cars In BID Passing Through To Edge" value: length(car where ((bid_geom != nil) and (each.location intersects bid_geom) and (each.phase = "moving") and (each.destination_type = "edge")));
			monitor "Traffic | Failed To Park Then Left" value: cars_failed_parking_and_left_count;

		display map type: 2d {
			species water_body;
			species road;
			species bid_boundary aspect: debug_geom;
			species parking_space;
			species public_parking_facility;
			species car;
		}

			display parking_capacity_and_occupancy {
				chart "Street vs Garage: Occupied and Free Spots" type: series style: spline {
					data "Street Occupied" value: length(parking_space where (each.occupied)) color: #red;
					data "Street Free" value: length(parking_space where (not each.occupied)) color: #green;
					data "Garage Occupied" value: sum(public_parking_facility collect each.current_occupied) color: rgb(200,120,0);
					data "Garage Free" value: sum(public_parking_facility collect each.current_available) color: #yellow;
				}
				chart "Street vs Garage: Occupancy %" type: series style: spline {
					data "Street Occupancy %" value: 100.0 * (length(parking_space where (each.occupied)) / max([1.0, float(length(parking_space))])) color: #red;
					data "Garage Occupancy %" value: 100.0 * (sum(public_parking_facility collect each.current_occupied) / max([1.0, float(sum(public_parking_facility collect each.licensed_capacity))])) color: rgb(200,120,0);
				}
			}

			display cars_in_bid_by_intent_over_time {
				chart "Cars In BID: Parking vs Passing Through" type: series style: spline {
					data "Looking For Parking" value: length(car where ((bid_geom != nil) and (each.location intersects bid_geom) and (each.phase = "moving") and (each.destination_type = "parking"))) color: #blue;
					data "Passing Through To Edge" value: length(car where ((bid_geom != nil) and (each.location intersects bid_geom) and (each.phase = "moving") and (each.destination_type = "edge"))) color: rgb(255,140,0);
				}
			}

			display failed_parking_then_left_over_time {
				chart "Failed To Park Then Left (Cumulative)" type: series style: spline {
					data "Failed To Park Then Left (Total)" value: (cars_failed_parking_and_left_count + cars_failed_garage_and_left_count) color: rgb(120,120,120);
					data "Street Parking Failed Then Left" value: cars_failed_parking_and_left_count color: rgb(180,60,60);
					data "Garage Failed Then Left" value: cars_failed_garage_and_left_count color: rgb(80,80,80);
				}
			}
	}
}
