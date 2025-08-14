extends MeshInstance3D

const THICKNESS_MODIFIER := 25

var mesh_export_thread: Thread = Thread.new()
var slices: Array[Dictionary] = []
var edges: Array[Array] = []

func _ready() -> void:
	mesh = build_mesh_from_csv_streaming(
		"res://Data/survey.csv",
		"res://Data/apertures.csv"
	)
	OBJExporter.export_progress_updated.connect(func (sid: int, prog: float): print("Exporting surface %s, %.02d/100 complete." % [sid, prog * 100]))
	OBJExporter.export_completed.connect(func (_obj, _mtl): print("Export complete!"))


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.keycode == KEY_M and event.pressed and not event.echo:
			_export_mesh()


func _export_mesh() -> void:
	mesh_export_thread.start(OBJExporter.save_mesh_to_files.bind($"../MeshInstance3D".mesh, "user://", "lhc"))


func _exit_tree() -> void:
	mesh_export_thread.wait_to_finish()


func _parse_slice_line(line: PackedStringArray) -> Dictionary:
	if line.size() < 7:
		return {}
	return {
		"center": Vector3(float(line[1]), float(line[2]), float(line[3])),
		"theta":  deg_to_rad(float(line[4])),
		"phi":    deg_to_rad(float(line[5])),
		"psi":    deg_to_rad(float(line[6])),
	}


func _parse_edge_line(line: PackedStringArray) -> Array[Vector2]:
	var points: Array[Vector2] = []
	if line.size() < 5:
		return points
		
	var xs: Array = _marshall_python_array_to_godot_array(line[3])
	var ys: Array = _marshall_python_array_to_godot_array(line[4])
	
	if xs.size() == 0 or ys.size() == 0 or xs[0] == null or ys[0] == null:
		return points
	
	var n: int = min(xs.size(), ys.size())
	points.resize(n)
	for i in n:
		if xs[i] != null and ys[i] != null:
			points[i] = Vector2(xs[i], ys[i])
		else:
			points[i] = Vector2.ZERO
	return points


func build_mesh_from_csv_streaming(slices_path: String, edges_path: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var sf := FileAccess.open(slices_path, FileAccess.READ)
	var ef := FileAccess.open(edges_path, FileAccess.READ)
	if sf == null or ef == null:
		push_error("Could not open one or both CSV files.")
		return ArrayMesh.new()

	# Skip headers
	sf.get_csv_line()
	ef.get_csv_line()

	var has_prev: bool = false
	var prev_slice: Dictionary = {}
	var prev_verts: Array[Vector3] = []
	var prev_tangent: Vector3 = Vector3.FORWARD
	var triangle_count: int = 0
	var prev_angle_offset: float = 0.0

	while not sf.eof_reached() and not ef.eof_reached():
		var sf_line := sf.get_csv_line()
		var ef_line := ef.get_csv_line()
		
		# Validate line lengths
		if sf_line.size() < 7 or ef_line.size() < 5:
			continue
			
		var curr_slice = _parse_slice_line(sf_line)
		var curr_edges = _parse_edge_line(ef_line)
		
		# Skip invalid data
		if curr_slice.size() == 0 or curr_edges.size() == 0:
			continue
		
		# Give it up for Frenet frames (because using Basis.from_euler() kept giving me shearing)
		var curr_center = curr_slice.center
		var tangent: Vector3
		var normal: Vector3
		var binormal: Vector3
		
		if has_prev:
			tangent = curr_center - prev_slice.center
		else:
			tangent = prev_tangent
		
		if tangent.length_squared() < 1e-12:
			tangent = prev_tangent
		
		var up = Vector3.UP
		if abs(tangent.dot(up)) > 0.9:
			up = Vector3.RIGHT

		normal = (up - tangent * up.dot(tangent)).normalized()
		binormal = tangent.cross(normal).normalized()
		
		if "psi" in curr_slice and abs(curr_slice.psi) > 1e-6:
			normal = normal.rotated(tangent, curr_slice.psi)
			binormal = binormal.rotated(tangent, curr_slice.psi)
			
		prev_tangent = tangent
		
		slices.append(curr_slice)
		
		var curr_verts: Array[Vector3] = []
		curr_verts.resize(curr_edges.size())
		for i in curr_edges.size():
			var p2 = curr_edges[i] * THICKNESS_MODIFIER
			curr_verts[i] = curr_center + normal * p2.x + binormal * p2.y
		
		edges.append(curr_verts)
		
		# Rotation minimisation to stop the classic Frenet twisting
		if has_prev and prev_verts.size() == curr_verts.size():
			var num_verts = prev_verts.size()

			var prev_center = prev_slice.center
			var curr_center_calc = curr_slice.center

			# Reference vectors: first vertex relative to ring center
			var ref_prev = (prev_verts[0] - prev_center).normalized()
			var ref_curr = (curr_verts[0] - curr_center_calc).normalized()

			# Tangent from positions
			var tangent_dir = (curr_center_calc - prev_center).normalized()
			if tangent_dir.length_squared() < 1e-12:
				tangent_dir = prev_tangent.normalized()

			# Measure signed rotation around tangent
			var dot_val = clamp(ref_prev.dot(ref_curr), -1.0, 1.0)
			var cross_val = tangent_dir.dot(ref_prev.cross(ref_curr))
			var angle_diff = atan2(cross_val, dot_val)

			# Accumulate roll
			prev_angle_offset += angle_diff

			# Convert to vertex index shift
			var index_shift = int(round(prev_angle_offset / (TAU / num_verts)))

			# Apply index rotation
			var rotated_ring: Array[Vector3] = []
			rotated_ring.resize(num_verts)
			for i in num_verts:
				rotated_ring[i] = curr_verts[(i + index_shift) % num_verts]

			curr_verts = rotated_ring
		
		# Stitch slices if we have a previous slice to connect polygons to
		if has_prev and prev_verts.size() == curr_verts.size() and curr_verts.size() > 2:
			var num_verts = curr_verts.size()
			
			for j in num_verts:
				var jn = (j + 1) % num_verts
				var v1 = prev_verts[j] # Previous slice, current point
				var v2 = curr_verts[j] # Current slice, current point
				var v1n = prev_verts[jn] # Previous slice, next point
				var v2n = curr_verts[jn] # Current slice, next point
				
				st.add_vertex(v1)
				st.add_vertex(v1n)
				st.add_vertex(v2)
				
				st.add_vertex(v1n)
				st.add_vertex(v2n)
				st.add_vertex(v2)

				triangle_count += 2
		
		prev_slice = curr_slice
		prev_verts = curr_verts
		has_prev = true

	
	print(
		"Mesh complete. Processed %s apertures, generated %s vertices and %s polygons." % 
			[slices.size(), edges.reduce(func (acc, cur): return acc + cur.size(), 0), triangle_count]
	)
	
	st.index()
	st.generate_normals()
	return st.commit()


func _marshall_python_array_to_godot_array(arr_str: String) -> Array:
	arr_str = arr_str.strip_edges().trim_prefix("[").trim_suffix("]")
	var result: Array = []
	if arr_str == "":
		return result
	
	for num_str in arr_str.split(","):
		num_str = num_str.strip_edges()
		if num_str == "None" or num_str == "":
			result.append(null)
		else:
			result.append(float(num_str))
	return result
