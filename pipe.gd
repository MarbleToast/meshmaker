extends Node3D

@export var aperture_material: Material
@export var beam_material: Material

@onready var aperture_progress_container := $"../VBoxContainer/HBoxContainer"
@onready var beam_progress_container := $"../VBoxContainer/HBoxContainer2"
@onready var aperture_progress := %ApertureProgress
@onready var beam_progress := %BeamProgress
@onready var aperture_info := %ApertureInfo

# Aperture constants
const APERTURE_TORUS_SCALE_FACTOR := 1 # Factor to multiply the scale of cross-section positions
const APERTURE_THICKNESS_MODIFIER := 25 # Factor to multiply local cross-section vertices 

# Beam constants
const BEAM_FUDGED_EMITTANCE_X := 2.5e-6 / 16000 # Dummy factor for st.dev. in X to calculate beam width
const BEAM_FUDGED_EMITTANCE_Y := 2.5e-6 / 16000 # Dummy factor for st.dev. in Y to calculate beam height
const BEAM_NUM_SIGMAS := 3 # Number of standard deviations
const BEAM_SIGMA_DELTA := 8e-4 # Honestly no clue, but it's in the calculation. Some scalar
const BEAM_ELLIPSE_RESOLUTION := 10 # Number of vertices in each cross-section for beam
const BEAM_THICKNESS_MODIFIER := 0.1 # Factor to multiply local cross-section vertices

# Signals for coordinating threads
signal aperture_mesh_ready(mesh_data: Dictionary)
signal aperture_meshes_complete
signal beam_mesh_ready(arrays: ArrayMesh)

# Set up threads for mesh generation and exporting, so we don't have crazy loading times for
# each of these in sequence
var mesh_export_thread := Thread.new()
var aperture_thread := Thread.new()
var beam_thread := Thread.new()

# Store child MeshInstance3D nodes for different aperture segments
var beam_mesh_instance: MeshInstance3D
var aperture_mesh_instances: Array[MeshInstance3D] = []

var selected_aperture_mesh: ElementMeshInstance:
	set(value):
		if selected_aperture_mesh:
			selected_aperture_mesh.mesh.surface_get_material(0).emission_enabled = false
		value.mesh.surface_get_material(0).emission_enabled = true
		aperture_info.text = value.type
		selected_aperture_mesh = value

## Converts a stringified Python list to a Godot array
##
## Should be fairly portable for types other than floats, and converts None to null.
func _python_list_to_godot_array(arr_str: String) -> Array:
	arr_str = arr_str.strip_edges().trim_prefix("[").trim_suffix("]")
	var result: Array = []
	if arr_str == "":
		return result
	
	for num_str in arr_str.split(","):
		num_str = num_str.strip_edges()
		if num_str == "None" or num_str == "":
			result.append(null)
		else:
			result.append(str_to_var(num_str))
	return result


var colour_map := {}
func _element_type_to_colour(type: String) -> Color:
	if type in colour_map:
		return colour_map[type]
	var h := type.hash()
	var r = float((h >> 16) & 0xFF) / 255.0
	var g = float((h >> 8) & 0xFF) / 255.0
	var b = float(h & 0xFF) / 255.0
	var colour := Color(r, g, b, 0.3)
	colour_map[type] = colour
	return colour


## Parses a line of aperture data from an Xsuite survey CSV
func _parse_survey_line(line: PackedStringArray) -> Dictionary:
	if len(line) < 7:
		return {}
	return {
		center = Vector3(float(line[1]), float(line[2]), float(line[3])) * APERTURE_TORUS_SCALE_FACTOR,
		psi = deg_to_rad(float(line[6])),
		type = line[14]
	}


## Parses a line of beam envelope data from an Xsuite twiss CSV
func _parse_twiss_line(line: PackedStringArray) -> Dictionary:
	if len(line) < 7:
		return {}
	
	return {
		position = Vector2(float(line[3]), float(line[5])),
		sigma = Vector2(
			BEAM_SIGMA_DELTA * BEAM_NUM_SIGMAS * sqrt(BEAM_FUDGED_EMITTANCE_X * float(line[17])) + absf(float(line[23])),
			BEAM_SIGMA_DELTA * BEAM_NUM_SIGMAS * sqrt(BEAM_FUDGED_EMITTANCE_Y * float(line[18])) + absf(float(line[25]))
		)
	}


## Parses a line of aperture vertex data from an Xsuite apertures CSV
func _parse_edge_line(line: PackedStringArray) -> Array[Vector2]:
	var points: Array[Vector2] = []
	if len(line) < 5:
		return points
		
	var xs: Array = _python_list_to_godot_array(line[3])
	var ys: Array = _python_list_to_godot_array(line[4])
	
	if len(xs) == 0 or len(ys) == 0 or xs[0] == null or ys[0] == null:
		return points
	
	var n: int = min(len(xs), len(ys))
	points.resize(n)
	for i in n:
		if xs[i] != null and ys[i] != null:
			points[i] = Vector2(xs[i], ys[i])
		else:
			points[i] = Vector2.ZERO
	return points


# Reads and parses all lines from an Xsuite survey file, discarding non-usable lines
func _load_survey(survey_path: String) -> Array[Dictionary]:
	print("Loading survey data...")
	var sf := FileAccess.open(survey_path, FileAccess.READ)
	
	# Skip header
	sf.get_csv_line()
	
	var apertures: Array[Dictionary] = []
	while not sf.eof_reached():
		var slice_line := sf.get_csv_line()
		if len(slice_line) < 5:
			continue
			
		var curr_slice := _parse_survey_line(slice_line)
		if curr_slice.is_empty():
			continue
			
		apertures.append(curr_slice)
	
	print("Got %s apertures." % apertures.size())
	return apertures


## Loads all lines from an Xsuite aperture file into an array
## 
## We need to have all lines because _parse_edge_line() discards lines without vertex data,
## meaning we would drop out of sync with the survey file when creating aperture segments 
func _load_aperture_edge_lines(edges_path: String) -> Array[PackedStringArray]:
	print("Loading edge data...")
	var ef := FileAccess.open(edges_path, FileAccess.READ)

	# Skip header
	ef.get_csv_line()
	
	var edges: Array[PackedStringArray] = []
	while not ef.eof_reached():
		var edges_line := ef.get_csv_line()
		if len(edges_line) < 5:
			continue
		edges.append(edges_line)
	
	print("Got %s aperture edges." % edges.size())
	return edges


## Builds segments of consecutive survey slices of the same type
func _build_aperture_segments(survey_data: Array[Dictionary], edges_data: Array[PackedStringArray]) -> Array[Dictionary]:
	print("Building segments...")
	var segments: Array[Dictionary] = []
	var current_type := ""
	var current_segment := {
		type = "", 
		survey = [], 
		edges = [] 
	}

	for i in survey_data.size():
		var slice := survey_data[i]
		if slice.type != current_type:
			# Push previous segment if it's not the first line
			if current_segment.survey.size() > 0:
				segments.append(current_segment)
				
			# Start new segment
			current_type = slice.type
			current_segment = {
				type = current_type, 
				survey = [], 
				edges = [] 
			}
		
		var parsed_edges := _parse_edge_line(edges_data[i])
		if len(parsed_edges) == 0:
			continue
			
		current_segment.survey.append(slice)
		current_segment.edges.append(parsed_edges)

	# push last
	if current_segment.survey.size() > 0:
		segments.append(current_segment)

	return segments


## Creates an ellipse from a parsed twiss line, with width and height according to sigma in x and y
func _create_ellipse(twiss: Dictionary) -> Array[Vector2]:
	var pts: Array[Vector2] = []
	var center: Vector2 = twiss.position
	var sigma: Vector2 = twiss.sigma
	var step := TAU / float(BEAM_ELLIPSE_RESOLUTION)
	
	for i in BEAM_ELLIPSE_RESOLUTION:
		var angle := i * step
		pts.append(center + Vector2(cos(angle) * sigma.x, sin(angle) * sigma.y))

	return pts


## Signal callback for aperture_meshes_ready - now handles multiple segment meshes
func _on_aperture_mesh_ready(mesh_data: Dictionary) -> void:
	var aperture_type: String = mesh_data.type
	var array_mesh: ArrayMesh = mesh_data.arrays
	var segment_index: int = mesh_data.segment_index
	
	var mesh_instance := ElementMeshInstance.new()
	mesh_instance.name = "Aperture_Segment_%d_%s" % [segment_index, aperture_type]
	array_mesh.surface_set_material(0, aperture_material.duplicate())
	mesh_instance.mesh = array_mesh
	mesh_instance.type = aperture_type
	
	var static_body := StaticBody3D.new()
	static_body.input_event.connect(_on_aperture_mesh_clicked.bind(mesh_instance))
	
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = array_mesh.create_convex_shape()
	
	aperture_mesh_instances.append(mesh_instance)
	static_body.add_child(mesh_instance)
	static_body.add_child(collision_shape)
	add_child(static_body)


func _on_aperture_meshes_complete() -> void:
	_progress_success_animation(aperture_progress_container)


func _on_aperture_mesh_clicked(
	camera: Node, 
	event: InputEvent, 
	event_position: Vector3, 
	normal: Vector3, 
	shape_index: int, 
	caller: ElementMeshInstance
) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			selected_aperture_mesh = caller


## Signal callback for beam_mesh_ready
func _on_beam_mesh_ready(arrmesh: ArrayMesh) -> void:
	print("Beam mesh generated.")
	beam_mesh_instance = MeshInstance3D.new()
	beam_mesh_instance.name = "Twiss"
	add_child(beam_mesh_instance)
	
	arrmesh.surface_set_material(0, beam_material)
	beam_mesh_instance.mesh = arrmesh
	beam_progress.value = beam_progress.max_value
	_progress_success_animation(beam_progress_container)


func _progress_success_animation(container: Container) -> void:
	container.modulate = Color.LIME_GREEN
	await get_tree().create_tween().tween_property(container, "modulate", Color.TRANSPARENT, 2.0).finished
	container.queue_free()


func _exit_tree() -> void:
	if aperture_thread.is_started():
		aperture_thread.wait_to_finish()
	if beam_thread.is_started():
		beam_thread.wait_to_finish()
	if mesh_export_thread.is_started():
		mesh_export_thread.wait_to_finish()


func _ready() -> void:
	var survey_data := _load_survey("res://Data/survey.csv")
	var edges_lines := _load_aperture_edge_lines("res://Data/apertures.csv")
	var aperture_segments := _build_aperture_segments(survey_data, edges_lines)
	
	aperture_progress.max_value = aperture_segments.size()
	beam_progress.max_value = survey_data.size()

	aperture_mesh_ready.connect(_on_aperture_mesh_ready)
	aperture_meshes_complete.connect(_on_aperture_meshes_complete)
	beam_mesh_ready.connect(_on_beam_mesh_ready)
	
	aperture_thread.start(func ():
		_build_multiple_segmented_sweep_meshes(
			aperture_segments,
			func (progress: int):
				aperture_progress.set_value.call_deferred(progress)
		)
		aperture_meshes_complete.emit.call_deferred()
	)
	
	beam_thread.start(func ():
		var arrays := _build_sweep_mesh(
			survey_data, 
			"res://Data/twiss.csv", 

			func (twiss_line):
				var data: Array[Vector2]
				data.assign(_create_ellipse(_parse_twiss_line(twiss_line)).map(func(v): return v * BEAM_THICKNESS_MODIFIER))
				return data,

			func (progress: int):
				beam_progress.set_value.call_deferred(progress)
		)

		beam_mesh_ready.emit.call_deferred(arrays)
	)

	OBJExporter.export_progress_updated.connect(func (sid: int, prog: float): print("Exporting surface %s, %.02f/100 complete." % [sid, prog * 100]))
	OBJExporter.export_completed.connect(func (_obj, _mtl): print("Export complete!"))


##  Creates separate meshes for each aperture segment
func _build_multiple_segmented_sweep_meshes(segments: Array[Dictionary], progress_callback: Callable = Callable()) -> void:
	print("Building segmented meshes...")
	
	# Keep track of the last processed slice and its verts (across all segments)
	var prev_slice := {}
	var prev_verts: Array[Vector3] = []
	var prev_tangent := Vector3.FORWARD
	var prev_angle_offset := 0.0
	var has_prev := false
	
	for segment_index in range(segments.size()):
		var segment = segments[segment_index]
		var slices_data: Array = segment.survey
		var edges_data: Array = segment.edges
		var segment_type: String = segment.type
		
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_color(_element_type_to_colour(segment_type))
		
		# Process each slice normally
		for s in range(slices_data.size()):
			var curr_slice: Dictionary = slices_data[s]
			var edge_ring: Array[Vector2] = edges_data[s]
			
			# ---- build Frenet frame ----
			var curr_center: Vector3 = curr_slice.center
			var tangent: Vector3 = (curr_center - prev_slice.center) if has_prev else prev_tangent
			if tangent.length_squared() < 1e-12:
				tangent = prev_tangent
			
			var up := Vector3.UP
			if abs(tangent.dot(up)) > 0.9:
				up = Vector3.RIGHT
			
			var normal := (up - tangent * up.dot(tangent)).normalized()
			var binormal := tangent.cross(normal).normalized()
			if abs(curr_slice.psi) > 1e-6:
				normal  = normal.rotated(tangent, curr_slice.psi)
				binormal = binormal.rotated(tangent, curr_slice.psi)
			
			prev_tangent = tangent
			
			# ---- build verts ----
			var curr_verts: Array[Vector3] = []
			for p2 in edge_ring:
				var scaled := p2 * APERTURE_THICKNESS_MODIFIER
				curr_verts.append(curr_center + normal * scaled.x + binormal * scaled.y)
			
			# ---- stitch if we have a previous ring ----
			if has_prev and prev_verts.size() == curr_verts.size():
				var n := curr_verts.size()
				var ref_prev: Vector3 = prev_verts[0] - prev_slice.center
				var ref_curr := curr_verts[0] - curr_center
				var dot_val: float = clamp(ref_prev.dot(ref_curr), -1.0, 1.0)
				var cross_val := tangent.dot(ref_prev.cross(ref_curr))
				prev_angle_offset += atan2(cross_val, dot_val)
				
				var shift := int(round(prev_angle_offset / (TAU / float(n))))
				var rotated: Array[Vector3] = []
				for i in range(n):
					rotated.append(curr_verts[(i + shift) % n])
				curr_verts = rotated
				
				for j in range(n):
					var jn = (j + 1) % n
					st.add_vertex(prev_verts[j])
					st.add_vertex(prev_verts[jn])
					st.add_vertex(curr_verts[j])
					
					st.add_vertex(prev_verts[jn])
					st.add_vertex(curr_verts[jn])
					st.add_vertex(curr_verts[j])
			
			prev_slice = curr_slice
			prev_verts = curr_verts
			has_prev = true
			
			prev_slice = curr_slice
			prev_verts = curr_verts
			prev_tangent = tangent
			
		progress_callback.call(segment_index)

		# finalize surface for this segment
		st.index()
		st.generate_normals()
		st.optimize_indices_for_cache()
		
		aperture_mesh_ready.emit.call_deferred({
			type = segment_type,
			arrays = st.commit(),
			segment_index = segment_index
		})
	
	print("Aperture mesh generation complete.")


## Creates a SurfaceTool and populates it with toroidal data, to be committed to an ArrayMesh or to arrays
func _build_sweep_mesh(survey_data: Array[Dictionary], data_path: String, get_points_func: Callable, progress_callback: Callable = Callable()) -> ArrayMesh:
	print("Building mesh from %s..." % data_path)
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var df := FileAccess.open(data_path, FileAccess.READ)
	if df == null:
		push_error("Could not open data CSV file.")
		return ArrayMesh.new()
		
	# Skip headers
	df.get_csv_line()
	
	var aperture_index := 0
	var has_prev := false
	var prev_slice := {}
	var prev_verts: Array[Vector3] = []
	var prev_tangent := Vector3.FORWARD
	var prev_angle_offset := 0.0
	var triangle_count := 0
	var prev_type: String = survey_data[0].type

	while not df.eof_reached():
		var data_line := df.get_csv_line()
		if len(data_line) < 5:
			continue

		var curr_slice := survey_data[aperture_index]
		aperture_index += 1

		# Get the 2D cross-section points via callback
		var points_2d: Array[Vector2] = get_points_func.call(data_line)
		if points_2d.is_empty():
			continue
			
		if prev_type != curr_slice.type:
			st.set_color(_element_type_to_colour(curr_slice.type))

		# Here, we're essentially finding the rotation to angle our edge vertices by finding
		# the direction from one slice to the next as our tangent, then getting its normal and 
		# binormal. This lets us build our own Frenet frame, which we can then minimise the
		# rotation on to prevent Frenet twist
		var curr_center: Vector3 = curr_slice.center
		var tangent: Vector3 = (curr_center - prev_slice.center) if has_prev else prev_tangent
		
		# To catch weird edge cases like two slices intersecting
		if tangent.length_squared() < 1e-12:
			tangent = prev_tangent

		var up := Vector3.UP
		if abs(tangent.dot(up)) > 0.9:
			up = Vector3.RIGHT

		var normal := (up - tangent * up.dot(tangent)).normalized()
		var binormal := tangent.cross(normal).normalized()
		if abs(curr_slice.psi) > 1e-6:
			normal = normal.rotated(tangent, curr_slice.psi)
			binormal = binormal.rotated(tangent, curr_slice.psi)

		prev_tangent = tangent

		# Build those vertices in 3D space
		var curr_verts : Array[Vector3] = []
		for i in len(points_2d):
			var p2 := points_2d[i]
			curr_verts.append(curr_center + normal * p2.x + binormal * p2.y)

		# Stitching process. If we have a previous slice, then we minimise the rotation
		# and stitch them together
		if has_prev:
			var num_verts := len(curr_verts)
			var ref_prev: Vector3 = prev_verts[0] - prev_slice.center
			var ref_curr: Vector3 = curr_verts[0] - curr_center

			var dot_val = clamp(ref_prev.dot(ref_curr), -1.0, 1.0)
			var cross_val = tangent.dot(ref_prev.cross(ref_curr))
			prev_angle_offset += atan2(cross_val, dot_val)

			var index_shift := int(round(prev_angle_offset / (TAU / num_verts)))
			var rotated_ring: Array[Vector3] = []
			for i in num_verts:
				rotated_ring.append(curr_verts[(i + index_shift) % num_verts])

			curr_verts = rotated_ring

			for j in len(curr_verts):
				var jn = (j + 1) % len(curr_verts)
				st.add_vertex(prev_verts[j])
				st.add_vertex(prev_verts[jn])
				st.add_vertex(curr_verts[j])

				st.add_vertex(prev_verts[jn])
				st.add_vertex(curr_verts[jn])
				st.add_vertex(curr_verts[j])

				triangle_count += 2

		prev_slice = curr_slice
		prev_verts = curr_verts
		has_prev = true
		
		progress_callback.call(aperture_index)

	st.index()
	st.generate_normals()
	st.optimize_indices_for_cache()
	return st.commit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.keycode == KEY_M and event.pressed and not event.echo:
			_export_mesh()


## Export all meshes
func _export_mesh() -> void:
	mesh_export_thread.start(func():
		if beam_mesh_instance:
			OBJExporter.save_mesh_to_files(beam_mesh_instance.mesh, "user://", "mesh_export_beam")
		for inst in aperture_mesh_instances:
			if inst.mesh:
				OBJExporter.save_mesh_to_files(inst.mesh, "user://", "mesh_export_%s" % inst.name)
	)
