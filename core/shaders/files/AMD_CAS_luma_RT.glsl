// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v1.1.4/sdk/include/FidelityFX/gpu/cas/ffx_cas.h

*/


//!PARAM STR
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.5


//!HOOK LUMA
//!BIND HOOKED
//!DESC [AMD_CAS_luma_RT] (SDK v1.1.4)
//!WHEN STR

#define min3(a, b, c) min(a, min(b, c))
#define max3(a, b, c) max(a, max(b, c))

ivec2 cas_clamp(ivec2 p) { return clamp(p, ivec2(0), ivec2(HOOKED_size) - 1); }

vec4 hook() {

	ivec2 pos = ivec2(HOOKED_pos * HOOKED_size);

	//  a b c
	//  d e f
	//  g h i
	float a = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2(-1, -1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float b = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2( 0, -1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float c = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2( 1, -1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float d = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2(-1,  0)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float e = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos),                 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float f = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2( 1,  0)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float g = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2(-1,  1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float h = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2( 0,  1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;
	float i = linearize(vec4(texelFetch(HOOKED_raw, cas_clamp(pos + ivec2( 1,  1)), 0).x * HOOKED_mul, 0.0, 0.0, 1.0)).x;

	//    b
	//  d e f
	//    h
	float mnL = min3(min3(d, e, f), b, h);
	float mnL2 = min3(min3(mnL, a, c), g, i);
	mnL += mnL2;

	float mxL = max3(max3(d, e, f), b, h);
	float mxL2 = max3(max3(mxL, a, c), g, i);
	mxL += mxL2;

	float ampL = clamp(min(mnL, 2.0 - mxL) / mxL, 0.0, 1.0);
	ampL = sqrt(ampL);

	//  0 w 0
	//  w 1 w
	//  0 w 0
	float peak = -1.0 / mix(8.0, 5.0, STR);
	float wL = ampL * peak;

	float rcpWeight = 1.0 / (1.0 + 4.0 * wL);
	float result = clamp((b * wL + d * wL + f * wL + h * wL + e) * rcpWeight, 0.0, 1.0);
	result = delinearize(vec4(result, 0.0, 0.0, 1.0)).x;
	return vec4(result, 0.0, 0.0, 1.0);

}

