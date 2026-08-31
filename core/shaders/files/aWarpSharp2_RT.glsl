// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- AviSynth ver.
  http://ldesoras.fr/src/avs/awarpsharp2-2015.12.30.zip
  --- VapourSynth ver.
  https://github.com/dubhater/vapoursynth-awarpsharp2

*/


//!PARAM STR
//!TYPE float
//!MINIMUM -20.0
//!MAXIMUM 20.0
4.0

//!PARAM ET
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 255.0
128.0

//!PARAM BP
//!TYPE int
//!MINIMUM 1
//!MAXIMUM 4
2


//!HOOK LUMA
//!BIND HOOKED
//!SAVE SOBEL_MASK
//!DESC [aWarpSharp2_RT] blur pre
//!WHEN STR

vec4 hook() {
	float a11 = HOOKED_texOff(vec2(-1.0, -1.0)).r, a21 = HOOKED_texOff(vec2(0.0, -1.0)).r, a31 = HOOKED_texOff(vec2(1.0, -1.0)).r;
	float a12 = HOOKED_texOff(vec2(-1.0, 0.0)).r, a32 = HOOKED_texOff(vec2(1.0, 0.0)).r;
	float a13 = HOOKED_texOff(vec2(-1.0, 1.0)).r, a23 = HOOKED_texOff(vec2(0.0, 1.0)).r, a33 = HOOKED_texOff(vec2(1.0, 1.0)).r;
	float avg_u = (a21 + (a11 + a31)*0.5)*0.5;
	float avg_d = (a23 + (a13 + a33)*0.5)*0.5;
	float avg_l = (a12 + (a13 + a11)*0.5)*0.5;
	float avg_r = (a32 + (a33 + a31)*0.5)*0.5;
	float abs_v = abs(avg_u - avg_d);
	float abs_h = abs(avg_l - avg_r);
	float absolute = min(abs_v + abs_h, 1.0);
	absolute = min(absolute + max(abs_h, abs_v), 1.0);
	absolute = min(min(absolute * 2.0, 1.0) + absolute, 1.0);
	absolute = min(absolute * 2.0, 1.0);
	return vec4(vec3(min(absolute, ET/255.0)), 1.0);
}

//!HOOK LUMA
//!BIND SOBEL_MASK
//!SAVE BLUR_H_1
//!DESC [aWarpSharp2_RT] blur pass1H
//!WHEN STR BP 0 > *

vec4 hook() {
	float c = SOBEL_MASK_texOff(vec2(0, 0)).r, n1 = (SOBEL_MASK_texOff(vec2(-1, 0)).r + SOBEL_MASK_texOff(vec2(1, 0)).r)*0.5, n2 = (SOBEL_MASK_texOff(vec2(-2, 0)).r + SOBEL_MASK_texOff(vec2(2, 0)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_H_1
//!SAVE BLUR_V_1
//!DESC [aWarpSharp2_RT] blur pass1V
//!WHEN STR BP 0 > *

vec4 hook() {
	float c = BLUR_H_1_texOff(vec2(0, 0)).r, n1 = (BLUR_H_1_texOff(vec2(0, -1)).r + BLUR_H_1_texOff(vec2(0, 1)).r)*0.5, n2 = (BLUR_H_1_texOff(vec2(0, -2)).r + BLUR_H_1_texOff(vec2(0, 2)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_V_1
//!SAVE BLUR_H_2
//!DESC [aWarpSharp2_RT] blur pass2H
//!WHEN STR BP 1 > *

vec4 hook() {
	float c = BLUR_V_1_texOff(vec2(0, 0)).r, n1 = (BLUR_V_1_texOff(vec2(-1, 0)).r + BLUR_V_1_texOff(vec2(1, 0)).r)*0.5, n2 = (BLUR_V_1_texOff(vec2(-2, 0)).r + BLUR_V_1_texOff(vec2(2, 0)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_H_2
//!SAVE BLUR_V_2
//!DESC [aWarpSharp2_RT] blur pass2V
//!WHEN STR BP 1 > *

vec4 hook() {
	float c = BLUR_H_2_texOff(vec2(0, 0)).r, n1 = (BLUR_H_2_texOff(vec2(0, -1)).r + BLUR_H_2_texOff(vec2(0, 1)).r)*0.5, n2 = (BLUR_H_2_texOff(vec2(0, -2)).r + BLUR_H_2_texOff(vec2(0, 2)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_V_2
//!SAVE BLUR_H_3
//!DESC [aWarpSharp2_RT] blur pass3H
//!WHEN STR BP 2 > *

vec4 hook() {
	float c = BLUR_V_2_texOff(vec2(0, 0)).r, n1 = (BLUR_V_2_texOff(vec2(-1, 0)).r + BLUR_V_2_texOff(vec2(1, 0)).r)*0.5, n2 = (BLUR_V_2_texOff(vec2(-2, 0)).r + BLUR_V_2_texOff(vec2(2, 0)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_H_3
//!SAVE BLUR_V_3
//!DESC [aWarpSharp2_RT] blur pass3V
//!WHEN STR BP 2 > *

vec4 hook() {
	float c = BLUR_H_3_texOff(vec2(0, 0)).r, n1 = (BLUR_H_3_texOff(vec2(0, -1)).r + BLUR_H_3_texOff(vec2(0, 1)).r)*0.5, n2 = (BLUR_H_3_texOff(vec2(0, -2)).r + BLUR_H_3_texOff(vec2(0, 2)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_V_3
//!SAVE BLUR_H_4
//!DESC [aWarpSharp2_RT] blur pass4H
//!WHEN STR BP 3 > *

vec4 hook() {
	float c = BLUR_V_3_texOff(vec2(0, 0)).r, n1 = (BLUR_V_3_texOff(vec2(-1, 0)).r + BLUR_V_3_texOff(vec2(1, 0)).r)*0.5, n2 = (BLUR_V_3_texOff(vec2(-2, 0)).r + BLUR_V_3_texOff(vec2(2, 0)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND BLUR_H_4
//!SAVE BLUR_V_4
//!DESC [aWarpSharp2_RT] blur pass4V
//!WHEN STR BP 3 > *

vec4 hook() {
	float c = BLUR_H_4_texOff(vec2(0, 0)).r, n1 = (BLUR_H_4_texOff(vec2(0, -1)).r + BLUR_H_4_texOff(vec2(0, 1)).r)*0.5, n2 = (BLUR_H_4_texOff(vec2(0, -2)).r + BLUR_H_4_texOff(vec2(0, 2)).r)*0.5;
	float avg = (((n2 + c)*0.5 + c)*0.5 + n1)*0.5;
	return vec4(vec3(avg), 1.0);
}

//!HOOK LUMA
//!BIND HOOKED
//!BIND SOBEL_MASK
//!DESC [aWarpSharp2_RT] warp
//!WHEN STR BP 0 = *

// 效果太次 不使用
vec4 hook() {
	float Gx = SOBEL_MASK_texOff(vec2(-1, 0)).r - SOBEL_MASK_texOff(vec2(1,0)).r, Gy = SOBEL_MASK_texOff(vec2(0, -1)).r - SOBEL_MASK_texOff(vec2(0, 1)).r;
	return HOOKED_tex(HOOKED_pos + vec2(Gx, Gy)*STR*HOOKED_pt);
}

//!HOOK LUMA
//!BIND HOOKED
//!BIND BLUR_V_1
//!DESC [aWarpSharp2_RT] warp (1 blur)
//!WHEN STR BP 1 = *

vec4 hook() {
	float Gx = BLUR_V_1_texOff(vec2(-1, 0)).r - BLUR_V_1_texOff(vec2(1, 0)).r, Gy = BLUR_V_1_texOff(vec2(0, -1)).r - BLUR_V_1_texOff(vec2(0, 1)).r;
	return HOOKED_tex(HOOKED_pos + vec2(Gx, Gy)*STR*HOOKED_pt);
}

//!HOOK LUMA
//!BIND HOOKED
//!BIND BLUR_V_2
//!DESC [aWarpSharp2_RT] warp (2 blurs)
//!WHEN STR BP 2 = *

vec4 hook() {
	float Gx = BLUR_V_2_texOff(vec2(-1, 0)).r - BLUR_V_2_texOff(vec2(1, 0)).r, Gy = BLUR_V_2_texOff(vec2(0, -1)).r - BLUR_V_2_texOff(vec2(0, 1)).r;
	return HOOKED_tex(HOOKED_pos + vec2(Gx, Gy)*STR*HOOKED_pt);
}

//!HOOK LUMA
//!BIND HOOKED
//!BIND BLUR_V_3
//!DESC [aWarpSharp2_RT] warp (3 blurs)
//!WHEN STR BP 3 = *

vec4 hook() {
	float Gx = BLUR_V_3_texOff(vec2(-1, 0)).r - BLUR_V_3_texOff(vec2(1, 0)).r, Gy = BLUR_V_3_texOff(vec2(0, -1)).r - BLUR_V_3_texOff(vec2(0, 1)).r;
	return HOOKED_tex(HOOKED_pos + vec2(Gx, Gy)*STR*HOOKED_pt);
}

//!HOOK LUMA
//!BIND HOOKED
//!BIND BLUR_V_4
//!DESC [aWarpSharp2_RT] warp (4 blurs)
//!WHEN STR BP 4 = *

vec4 hook() {
	float Gx = BLUR_V_4_texOff(vec2(-1, 0)).r - BLUR_V_4_texOff(vec2(1, 0)).r, Gy = BLUR_V_4_texOff(vec2(0, -1)).r - BLUR_V_4_texOff(vec2(0, 1)).r;
	return HOOKED_tex(HOOKED_pos + vec2(Gx, Gy)*STR*HOOKED_pt);
}

