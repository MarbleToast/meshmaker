shader_type spatial;
render_mode diffuse_toon, specular_schlick_ggx, cull_disabled;

uniform float rim: hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float rim_threshold: hint_range(0.0, 1.0, 0.01) = 0.5;

uniform float emission: hint_range(0.0, 1.0, 0.1) = 0.0;
uniform float specular: hint_range(0.0, 1.0, 0.05) = 0.5;
uniform vec3 specular_color: source_color = vec3(0.5);
uniform float roughness: hint_range(0.0, 1.0, 0.1) = 1.0;
uniform float alpha: hint_range(0.0, 1.0, 0.1) = 1.0;

uniform bool is_normal_symmetric = false;
uniform float normal_scale: hint_range(0.0, 5.0, 0.1) = 1.0;
uniform sampler2D normal_map: hint_normal,repeat_enable;
uniform sampler2D roughness_map: hint_roughness_g,repeat_enable;
uniform vec4 albedo_color: source_color = vec4(1.0);
uniform vec4 albedo_color2: source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D diffuse_map: source_color,repeat_enable;

uniform sampler2D specular_map: hint_roughness_r,repeat_enable;
uniform sampler2D ramp: source_color, repeat_disable;

varying float s1;
varying vec3 vex;

vec3 get_gradient_color(float position) {
    return texture(ramp, vec2(position, 0.5)).rgb;
}

float fresnel(float amount, vec3 normal, vec3 view)
{
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0)), amount);
}

vec3 screen(vec3 base, vec3 blend){
	return 1.0 - (1.0 - base) * (1.0 - blend);
}
vec3 soft_light(vec3 base, vec3 blend){
	vec3 limit = step(0.5, blend);
	return mix(2.0 * base * blend + base * base * (1.0 - 2.0 * blend), sqrt(base) * (2.0 * blend - 1.0) + (2.0 * base) * (1.0 - blend), limit);
}

void vertex() {
	vex = VERTEX;
}

void fragment() {
	vec2 uv = UV;
	NORMAL_MAP = vec3(texture(normal_map, uv).xyz);
	NORMAL_MAP_DEPTH = normal_scale;
	if(is_normal_symmetric){
		vec3 normal_invert_y = NORMAL_MAP;
		normal_invert_y.y = 1.0 - normal_invert_y.y;
		if (vex.x < 0.0) {
			NORMAL_MAP = normal_invert_y;
		}
	}
	ALBEDO = vec3(texture(diffuse_map, uv).rgb) * albedo_color.rgb + albedo_color2.rgb;
	ROUGHNESS = texture(roughness_map, UV).g * roughness * 0.9;
	EMISSION = ALBEDO * emission;
	SPECULAR = texture(specular_map, UV).r * specular;
	s1 = SPECULAR;
	ALPHA = alpha;
}

void light(){
	float NdotL = dot(NORMAL, LIGHT);
	//rim
	float basic_fresnel = fresnel(3.0, NORMAL, VIEW);
	float gradient_rim = step(rim_threshold, basic_fresnel) * basic_fresnel * pow(rim, 0.5);
	//diffuse
	float NdotL_clamp = clamp(NdotL, -1.0f, 1.0f);
	float gradient = mix(0.01f,0.99f, (NdotL_clamp + 1.0)*0.5 * ATTENUATION);
	vec3 color_ramp = get_gradient_color(max(gradient, gradient_rim));
	vec3 diffus_light = ALBEDO * color_ramp;
	vec3 mix_diffus_light = soft_light(diffus_light, LIGHT_COLOR);
	DIFFUSE_LIGHT = mix(mix_diffus_light, diffus_light, 0.5);
	//specular
	float rr = mix(0.99f, 0.01f, ROUGHNESS);
	vec3 H = normalize(VIEW + LIGHT);
	float NdotH = clamp(dot(NORMAL, H), 0.0, 1.0) * ATTENUATION;
	float gradient2 = clamp(pow(NdotH, 16.0/(1.0-rr)), 0.1, 0.99);
	vec3 color_ramp2 = get_gradient_color(clamp(NdotH * (1.0-ROUGHNESS), 0.01, 0.99));
	color_ramp2 = mix(vec3(0.0), color_ramp2, gradient2);
	vec3 specular_color_rgb = min(color_ramp2, specular_color.rgb) * s1;
	vec3 specular_light = screen(specular_color_rgb, LIGHT_COLOR * rr * color_ramp2);
	SPECULAR_LIGHT += mix(vec3(0.0), specular_light, s1);
}