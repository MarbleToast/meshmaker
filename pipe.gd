extends MeshInstance3D

const THICKNESS_MODIFIER := 25

func _ready() -> void:
	mesh = build_mesh_from_csv_streaming(
		"res://Data/survey.csv",
		"res://Data/apertures.csv"
	)

# --- Utility: parse one slice line -> center + euler (radians) ---
func _parse_slice_line(line: PackedStringArray) -> Dictionary:
	if line.size() < 7:
		return {}
	return {
		"center": Vector3(float(line[1]), float(line[2]), float(line[3])),
		"theta":  deg_to_rad(float(line[4])),
		"phi":    deg_to_rad(float(line[5])),
		"psi":    deg_to_rad(float(line[6])),
	}


# --- Utility: one CSV step for edges -> Array[Vector2] ---
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


# --- Streaming version with proper state management ---
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

	# State for streaming processing
	var has_prev := false
	var prev_slice: Dictionary = {}
	var prev_verts: Array[Vector3] = []
	
	var triangle_count := 0
	var slice_count := 0

	# Process each slice as we read it
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
			
		slice_count += 1
		
		# Calculate frame for current slice
		var curr_center = curr_slice.center
		var tangent: Vector3
		var normal: Vector3
		var binormal: Vector3
		
		if has_prev:
			# Use direction from previous slice
			tangent = (curr_center - prev_slice.center).normalized()
		else:
			# For first slice, use forward direction or derive from data
			tangent = Vector3.FORWARD
		
		# Ensure valid tangent
		if tangent.length_squared() < 1e-12:
			tangent = Vector3.FORWARD
		
		# Calculate perpendicular frame
		var up = Vector3.UP
		if abs(tangent.dot(up)) > 0.9:
			up = Vector3.RIGHT
		normal = (up - tangent * up.dot(tangent)).normalized()
		binormal = tangent.cross(normal).normalized()
		
		# Apply roll if present
		if "psi" in curr_slice and abs(curr_slice.psi) > 1e-6:
			normal = normal.rotated(tangent, curr_slice.psi)
			binormal = binormal.rotated(tangent, curr_slice.psi)
		
		# Build current slice vertices
		var curr_verts: Array[Vector3] = []
		curr_verts.resize(curr_edges.size())
		for i in curr_edges.size():
			var p2 = curr_edges[i] * THICKNESS_MODIFIER
			curr_verts[i] = curr_center + normal * p2.x + binormal * p2.y
		
		# Create triangles if we have a previous slice
		if has_prev and prev_verts.size() == curr_verts.size() and curr_verts.size() > 2:
			var N = curr_verts.size()
			
			for j in N:
				var jn = (j + 1) % N
				var v1 = prev_verts[j]    # Previous slice, current point
				var v2 = curr_verts[j]    # Current slice, current point
				var v1n = prev_verts[jn]  # Previous slice, next point
				var v2n = curr_verts[jn]  # Current slice, next point
				
				# Triangle 1: v1 -> v1n -> v2 (counter-clockwise from outside)
				st.add_vertex(v1)
				st.add_vertex(v1n)
				st.add_vertex(v2)
				
				# Triangle 2: v1n -> v2n -> v2 (counter-clockwise from outside)
				st.add_vertex(v1n)
				st.add_vertex(v2n)
				st.add_vertex(v2)
				
				triangle_count += 2
		
		# Update state for next iteration
		prev_slice = curr_slice
		prev_verts = curr_verts
		has_prev = true

	sf.close()
	ef.close()
	
	print("Streaming: Processed ", slice_count, " slices, generated ", triangle_count, " triangles")
	
	if triangle_count == 0:
		print("Warning: No triangles generated")
		return ArrayMesh.new()
	
	st.generate_normals()
	return st.commit()

# --- CSV parsing helper ---
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
