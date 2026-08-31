// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://forum.doom9.org/showthread.php?p=1569035#post1569035
  --- Shiandow ver.
  https://forum.doom9.org/showthread.php?p=1698648#post1698648

*/


//!PARAM SSTR
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 8.0
0.5

//!PARAM CSTR
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
0.1

//!PARAM LSTR
//!TYPE float
//!MINIMUM 0.001
//!MAXIMUM 3.0
1.0

//!PARAM PSTR
//!TYPE float
//!MINIMUM 0.001
//!MAXIMUM 2.0
1.0

//!PARAM XSTR
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 0.25
0.0

//!PARAM XREP
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.0


//!HOOK LUMA
//!BIND HOOKED
//!SAVE RG11
//!DESC [FineSharp_RT] RemoveGrain11
//!WHEN SSTR
//!COMPONENTS 1

vec4 hook() {

	float luma = HOOKED_texOff(vec2(0.0)).r;

	luma += luma;
	luma += HOOKED_texOff(vec2( 0.0, -1.0)).r;
	luma += HOOKED_texOff(vec2(-1.0,  0.0)).r;
	luma += HOOKED_texOff(vec2( 1.0,  0.0)).r;
	luma += HOOKED_texOff(vec2( 0.0,  1.0)).r;
	luma += luma;
	luma += HOOKED_texOff(vec2(-1.0, -1.0)).r;
	luma += HOOKED_texOff(vec2( 1.0, -1.0)).r;
	luma += HOOKED_texOff(vec2(-1.0,  1.0)).r;
	luma += HOOKED_texOff(vec2( 1.0,  1.0)).r;
	luma *= 0.0625;

	return vec4(luma, 0.0, 0.0, 1.0);

}

//!HOOK LUMA
//!BIND RG11
//!SAVE RG4
//!DESC [FineSharp_RT] RemoveGrain4
//!WHEN SSTR
//!COMPONENTS 1

void sort(inout float a1, inout float a2) {
	float t = min(a1, a2);
	a2 = max(a1, a2);
	a1 = t;
}

float median3(float a1, float a2, float a3) {
	sort(a2, a3);
	sort(a1, a2);
	return min(a2, a3);
}

float median5(float a1, float a2, float a3, float a4, float a5) {
	sort(a1, a2);
	sort(a3, a4);
	sort(a1, a3);
	sort(a2, a4);
	return median3(a2, a3, a5);
}

float median9(float a1, float a2, float a3, float a4, float a5, float a6, float a7, float a8, float a9) {
	sort(a1, a2); sort(a3, a4); sort(a5, a6); sort(a7, a8);
	sort(a1, a3); sort(a5, a7);
	sort(a1, a5); sort(a3, a5); sort(a3, a7);
	sort(a2, a4); sort(a6, a8);
	sort(a4, a8); sort(a4, a6); sort(a2, a6);
	return median5(a2, a4, a5, a7, a9);
}

vec4 hook() {

	float t1 = RG11_texOff(vec2(-1.0, -1.0)).r;
	float t2 = RG11_texOff(vec2( 0.0, -1.0)).r;
	float t3 = RG11_texOff(vec2( 1.0, -1.0)).r;
	float t4 = RG11_texOff(vec2(-1.0,  0.0)).r;
	float t5 = RG11_texOff(vec2( 0.0,  0.0)).r;
	float t6 = RG11_texOff(vec2( 1.0,  0.0)).r;
	float t7 = RG11_texOff(vec2(-1.0,  1.0)).r;
	float t8 = RG11_texOff(vec2( 0.0,  1.0)).r;
	float t9 = RG11_texOff(vec2( 1.0,  1.0)).r;

	float median_luma = median9(t1, t2, t3, t4, t5, t6, t7, t8, t9);

	return vec4(median_luma, 0.0, 0.0, 1.0);

}

//!HOOK LUMA
//!BIND RG4
//!BIND HOOKED
//!SAVE FSPA
//!DESC [FineSharp_RT] part A
//!WHEN SSTR
//!COMPONENTS 1

float SharpDiff(float denoised_luma, float original_luma) {
	float t = original_luma - denoised_luma;
	float sign_t = sign(t);
	float LDMP = SSTR + 0.1;
	return sign_t * SSTR * pow(abs(t) / LSTR, 1.0 / PSTR) * ((t * t) / (t * t + LDMP / (255.0 * 255.0)));
}

vec4 hook() {

	float denoised_luma = RG4_texOff(vec2(0.0)).r;
	float original_luma = HOOKED_texOff(vec2(0.0)).r;

	float sd = SharpDiff(denoised_luma, original_luma);
	float luma_A = original_luma + sd;

	sd += sd;
	sd += SharpDiff(RG4_texOff(vec2( 0.0, -1.0)).r, HOOKED_texOff(vec2(0.0, -1.0)).r);
	sd += SharpDiff(RG4_texOff(vec2(-1.0,  0.0)).r, HOOKED_texOff(vec2(-1.0, 0.0)).r);
	sd += SharpDiff(RG4_texOff(vec2( 1.0,  0.0)).r, HOOKED_texOff(vec2(1.0, 0.0)).r);
	sd += SharpDiff(RG4_texOff(vec2( 0.0,  1.0)).r, HOOKED_texOff(vec2(0.0, 1.0)).r);

	sd += sd;
	sd += SharpDiff(RG4_texOff(vec2(-1.0, -1.0)).r, HOOKED_texOff(vec2(-1.0, -1.0)).r);
	sd += SharpDiff(RG4_texOff(vec2( 1.0, -1.0)).r, HOOKED_texOff(vec2(1.0, -1.0)).r);
	sd += SharpDiff(RG4_texOff(vec2(-1.0,  1.0)).r, HOOKED_texOff(vec2(-1.0, 1.0)).r);
	sd += SharpDiff(RG4_texOff(vec2( 1.0,  1.0)).r, HOOKED_texOff(vec2(1.0, 1.0)).r);

	sd *= 0.0625;
	luma_A -= CSTR * sd;

	return vec4(luma_A, 0.0, 0.0, 1.0);

}

//!HOOK LUMA
//!BIND FSPA
//!SAVE FSPB
//!DESC [FineSharp_RT] part B
//!WHEN SSTR
//!COMPONENTS 1

void sort(inout float a1, inout float a2) {
	float t = min(a1, a2);
	a2 = max(a1, a2);
	a1 = t;
}

void sort_min_max3(inout float a1, inout float a2, inout float a3) {
	sort(a1, a2); sort(a1, a3); sort(a2, a3);
}

void sort_min_max5(inout float a1, inout float a2, inout float a3, inout float a4, inout float a5) {
	sort(a1, a2); sort(a3, a4); sort(a1, a3); sort(a2, a4); sort(a1, a5); sort(a4, a5);
}

void sort_min_max7(inout float a1, inout float a2, inout float a3, inout float a4, inout float a5, inout float a6, inout float a7) {
	sort(a1, a2); sort(a3, a4); sort(a5, a6); sort(a1, a3); sort(a1, a5); sort(a2, a6); sort(a4, a5); sort(a1, a7); sort(a6, a7);
}

void sort_min_max9(inout float a1, inout float a2, inout float a3, inout float a4, inout float a5, inout float a6, inout float a7, inout float a8, inout float a9) {
	sort(a1, a2); sort(a3, a4); sort(a5, a6); sort(a7, a8); sort(a1, a3); sort(a5, a7); sort(a1, a5); sort(a2, a4); sort(a6, a7); sort(a4, a8); sort(a1, a9); sort(a8, a9);
}

void sort9_partial2(inout float a1, inout float a2, inout float a3, inout float a4, inout float a5, inout float a6, inout float a7, inout float a8, inout float a9) {
	sort_min_max9(a1, a2, a3, a4, a5, a6, a7, a8, a9);
	sort_min_max7(a2, a3, a4, a5, a6, a7, a8);
}

vec4 hook() {

	float luma_A = FSPA_texOff(vec2(0.0)).r;

	float t1 = FSPA_texOff(vec2(-1.0, -1.0)).r;
	float t2 = FSPA_texOff(vec2( 0.0, -1.0)).r;
	float t3 = FSPA_texOff(vec2( 1.0, -1.0)).r;
	float t4 = FSPA_texOff(vec2(-1.0,  0.0)).r;
	float t5 = luma_A;
	float t6 = FSPA_texOff(vec2( 1.0,  0.0)).r;
	float t7 = FSPA_texOff(vec2(-1.0,  1.0)).r;
	float t8 = FSPA_texOff(vec2( 0.0,  1.0)).r;
	float t9 = FSPA_texOff(vec2( 1.0,  1.0)).r;

	float avg_luma = (t1+t2+t3+t4+t5+t6+t7+t8+t9) / 9.0;
	float luma_B = luma_A + 9.9 * (luma_A - avg_luma);

	float s1=t1, s2=t2, s3=t3, s4=t4, s5=t5, s6=t6, s7=t7, s8=t8, s9=t9;
	sort9_partial2(s1, s2, s3, s4, s5, s6, s7, s8, s9);

	luma_B = max(luma_B, min(s2, luma_A));
	luma_B = min(luma_B, max(s8, luma_A));

	return vec4(luma_B, 0.0, 0.0, 1.0);

}

//!HOOK LUMA
//!BIND FSPA
//!BIND FSPB
//!DESC [FineSharp_RT] part C
//!WHEN SSTR

vec4 hook() {

	float luma_A = FSPA_texOff(vec2(0.0)).r;
	float luma_B = FSPB_texOff(vec2(0.0)).r;

	float edge = abs( FSPB_texOff(vec2(0.0,-1.0)).r +
					   FSPB_texOff(vec2(-1.0,0.0)).r +
					   FSPB_texOff(vec2(1.0,0.0)).r  +
					   FSPB_texOff(vec2(0.0,1.0)).r  - 4.0 * luma_B );

	float luma_C = mix(luma_A, luma_B, XSTR * (1.0 - clamp(edge * XREP, 0.0, 1.0)));
	return vec4(luma_C, 0.0, 0.0, 1.0);

}

