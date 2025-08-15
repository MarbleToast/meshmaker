extends MeshInstance3D

@export var aperture_material: Material
@export var beam_material: Material

const APERTURE_THICKNESS_MODIFIER := 25

const BEAM_FUDGED_EMITTANCE_X := 1e-8
const BEAM_FUDGED_EMITTANCE_Y := 1e-8
const BEAM_NUM_SIGMAS := 3
const BEAM_SIGMA_DELTA := 8e-4
const BEAM_ELLIPSE_RESOLUTION := 4
const BEAM_THICKNESS_MODIFIER := 1

signal aperture_mesh_ready(arrays: Array)
signal beam_mesh_ready(arrays: Array)

var mesh_export_thread := Thread.new()
var aperture_thread := Thread.new()
var beam_thread := Thread.new()


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


## Parses a line of aperture data from an Xsuite survey CSV
func _parse_aperture_line(line: PackedStringArray) -> Dictionary:
	if len(line) < 7:
		return {}
	return {
		center = Vector3(float(line[1]), float(line[2]), float(line[3])),
		psi = deg_to_rad(float(line[6])),
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
	var sf := FileAccess.open(survey_path, FileAccess.READ)
	
	# Skip header
	sf.get_csv_line()
	
	var apertures: Array[Dictionary] = []
	while not sf.eof_reached():
		var slice_line := sf.get_csv_line()
		if len(slice_line) < 5:
			continue
			
		var curr_slice := _parse_aperture_line(slice_line)
		if curr_slice.is_empty():
			continue
			
		apertures.append(curr_slice)
	
	return apertures


## Signal callback for aperture_mesh_ready
func _on_aperture_mesh_ready(arrays: Array) -> void:
	print("Aperture mesh generated.")
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, aperture_material)


## Signal callback for beam_mesh_ready
func _on_beam_mesh_ready(arrays: Array) -> void:
	print("Beam mesh generated.")
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, beam_material)


func _exit_tree() -> void:
	if aperture_thread.is_started():
		aperture_thread.wait_to_finish()
	if beam_thread.is_started():
		beam_thread.wait_to_finish()
	if mesh_export_thread.is_started():
		mesh_export_thread.wait_to_finish()


func _ready() -> void:
	print("Loading survey data...")
	var slices_data := _load_survey("res://Data/survey.csv")

	aperture_mesh_ready.connect(_on_aperture_mesh_ready)
	beam_mesh_ready.connect(_on_beam_mesh_ready)
	
	aperture_thread.start(func ():
		var arrays := _build_sweep_mesh(
			slices_data, 
			"res://Data/apertures.csv", 
			func (slice_line):
				var data: Array[Vector2]
				data.assign(_parse_edge_line(slice_line).map(func(v): return v * APERTURE_THICKNESS_MODIFIER))
				return data
		).commit_to_arrays()

		aperture_mesh_ready.emit.call_deferred(arrays)
	)
	
	beam_thread.start(func ():
		var arrays := _build_sweep_mesh(
			slices_data, 
			"res://Data/twiss.csv", 
			func (twiss_line):
				var data: Array[Vector2]
				data.assign(_create_ellipse(_parse_twiss_line(twiss_line)).map(func(v): return v * BEAM_THICKNESS_MODIFIER))
				return data
		).commit_to_arrays()

		beam_mesh_ready.emit.call_deferred(arrays)
	)

	OBJExporter.export_progress_updated.connect(func (sid: int, prog: float): print("Exporting surface %s, %.02f/100 complete." % [sid, prog * 100]))
	OBJExporter.export_completed.connect(func (_obj, _mtl): print("Export complete!"))


## Creates a SurfaceTool and populates it with toroidal data, to be committed to an ArrayMesh or to arrays
func _build_sweep_mesh(survey_data: Array[Dictionary], data_path: String, get_points_func: Callable) -> SurfaceTool:
	print("Building mesh from %s..." % data_path)
	
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var df := FileAccess.open(data_path, FileAccess.READ)
	if df == null:
		push_error("Could not open data CSV file.")
		return st
		
	# Skip headers
	df.get_csv_line()
	
	var aperture_index := 0
	var has_prev := false
	var prev_slice := {}
	var prev_verts: Array[Vector3] = []
	var prev_tangent := Vector3.FORWARD
	var prev_angle_offset := 0.0
	var triangle_count := 0

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

	st.index()
	st.generate_normals()
	st.optimize_indices_for_cache()
	return st


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.keycode == KEY_M and event.pressed and not event.echo:
			_export_mesh()


func _export_mesh() -> void:
	mesh_export_thread.start(OBJExporter.save_mesh_to_files.bind(mesh, "user://", "lhc_beam"))
