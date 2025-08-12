extends MeshInstance3D

const THICKNESS_MODIFIER := 250


func _ready() -> void:
	mesh = build_mesh_from_csv("res://Data/survey.csv", "res://Data/apertures.csv")


func _marshall_python_array_to_godot_array(arr_str: String) -> Array:
	arr_str = arr_str.strip_edges().trim_prefix("[").trim_suffix("]")
	var result: Array = []
	if arr_str == "":
		return result
	for num_str in arr_str.split(","):
		if num_str.strip_edges() == "None":
			result.append(null)
			break
		result.append(float(num_str.strip_edges()))
	return result


func build_mesh_from_csv(slices_path: String, edges_path: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var slices_file := FileAccess.open(slices_path, FileAccess.READ)
	var edges_file := FileAccess.open(edges_path, FileAccess.READ)

	if slices_file == null or edges_file == null:
		push_error("Could not open one or both CSV files")
		return null

	# Skip headers
	slices_file.get_csv_line()
	edges_file.get_csv_line()

	var prev_verts: Array[Vector3] = []
	var prev_i := 0

	while not slices_file.eof_reached() and not edges_file.eof_reached():
		var slice_line = slices_file.get_csv_line()
		var edge_line = edges_file.get_csv_line()

		if slice_line.size() < 2 or edge_line.size() < 2:
			continue

		# Parse slice transform from survey table
		var center = Vector3(float(slice_line[1]), float(slice_line[2]), float(slice_line[3]))
		var theta = deg_to_rad(float(slice_line[4]))
		var phi = deg_to_rad(float(slice_line[5]))
		var psi = deg_to_rad(float(slice_line[6]))
		var rot = Basis.from_euler(Vector3(phi, theta, psi))
		var xform = Transform3D(rot, center)

		# Parse edge points
		var points_x: Array = _marshall_python_array_to_godot_array(edge_line[4])
		var points_y: Array = _marshall_python_array_to_godot_array(edge_line[5])
		
		if points_x[0] == null or points_y[0] == null:
			continue

		var verts: Array[Vector3] = []
		for k in range(points_x.size()):
			var local_point = Vector3(points_x[k], points_y[k], 0) * THICKNESS_MODIFIER
			verts.append(xform * local_point)

		# If we have a previous slice, connect it
		if prev_verts.size() > 0:
			var N = prev_verts.size()
			for j in range(N):
				var next_j = (j + 1) % N

				var v1  = prev_verts[j]
				var v2  = verts[j]
				var v1n = prev_verts[next_j]
				var v2n = verts[next_j]

				var u      = float(j) / float(N)
				var u_next = float(next_j) / float(N)
				var v_low  = float(prev_i) / float(prev_i + 1) # crude V coord, could be improved
				var v_high = float(prev_i + 1) / float(prev_i + 1)

				# Triangle 1
				st.set_uv(Vector2(u, v_low))
				st.add_vertex(v1)

				st.set_uv(Vector2(u, v_high))
				st.add_vertex(v2)

				st.set_uv(Vector2(u_next, v_low))
				st.add_vertex(v1n)

				# Triangle 2
				st.set_uv(Vector2(u_next, v_low))
				st.add_vertex(v1n)

				st.set_uv(Vector2(u, v_high))
				st.add_vertex(v2)

				st.set_uv(Vector2(u_next, v_high))
				st.add_vertex(v2n)

		prev_verts = verts
		prev_i += 1

	# Normals for lighting
	st.generate_normals()

	return st.commit()
