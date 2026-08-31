// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://github.com/NVIDIAGameWorks/NVIDIAImageScaling/blob/v1.0.3/licence.txt

*/


//!PARAM SHARP
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.5

//!PARAM NIS_HDR_MODE
//!TYPE DEFINE
//!MINIMUM 0
//!MAXIMUM 2
0


//!HOOK MAIN
//!BIND HOOKED
//!DESC [NVSharpen_RT] (SDK v1.0.3)
//!WHEN SHARP
//!COMPUTE 32 32 256 1

// Constants
#define kSupportSize 5
#define NIS_BLOCK_WIDTH 32
#define NIS_BLOCK_HEIGHT 32
#define NIS_THREAD_GROUP_SIZE 256
#define kNumPixelsX (NIS_BLOCK_WIDTH + kSupportSize + 1)
#define kNumPixelsY (NIS_BLOCK_HEIGHT + kSupportSize + 1)

#define kHDRCompressionFactor 0.282842712

shared float shPixelsY[kNumPixelsY][kNumPixelsX];

// Sharpness parameters (computed from SHARP slider)
float getDetectRatio() { return 2.0 * 1127.0 / 1024.0; }
float getDetectThres() {
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return 32.0 / 1024.0;
#else
	return 64.0 / 1024.0;
#endif
}
float getMinContrastRatio() {
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return 1.5;
#else
	return 2.0;
#endif
}
float getMaxContrastRatio() {
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return 5.0;
#else
	return 10.0;
#endif
}

float getRatioNorm() {
	return 1.0 / (getMaxContrastRatio() - getMinContrastRatio());
}

float getSharpStartY() {
#if NIS_HDR_MODE == 2
	return 0.35;
#elif NIS_HDR_MODE == 1
	return 0.3;
#else
	return 0.45;
#endif
}

float getSharpEndY() {
#if NIS_HDR_MODE == 2
	return 0.55;
#elif NIS_HDR_MODE == 1
	return 0.5;
#else
	return 0.9;
#endif
}

float getSharpScaleY() {
	return 1.0 / (getSharpEndY() - getSharpStartY());
}

float getSharpStrengthMin() {
	float sharpen_slider = SHARP - 0.5;
	float MinScale = (sharpen_slider >= 0.0) ? 1.25 : 1.0;
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return max(0.0, 0.4 + sharpen_slider * MinScale * 1.1);
#else
	return max(0.0, 0.4 + sharpen_slider * MinScale * 1.2);
#endif
}

float getSharpStrengthMax() {
	float sharpen_slider = SHARP - 0.5;
	float MaxScale = (sharpen_slider >= 0.0) ? 1.25 : 1.75;
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return 2.2 + sharpen_slider * MaxScale * 1.8;
#else
	return 1.6 + sharpen_slider * MaxScale * 1.8;
#endif
}

float getSharpStrengthScale() {
	return getSharpStrengthMax() - getSharpStrengthMin();
}

float getSharpLimitMin() {
	float sharpen_slider = SHARP - 0.5;
	float LimitScale = (sharpen_slider >= 0.0) ? 1.25 : 1.0;
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return max(0.06, 0.10 + sharpen_slider * LimitScale * 0.28);
#else
	return max(0.1, 0.14 + sharpen_slider * LimitScale * 0.32);
#endif
}

float getSharpLimitMax() {
	float sharpen_slider = SHARP - 0.5;
	float LimitScale = (sharpen_slider >= 0.0) ? 1.25 : 1.0;
#if NIS_HDR_MODE == 1 || NIS_HDR_MODE == 2
	return 0.6 + sharpen_slider * LimitScale * 0.6;
#else
	return 0.5 + sharpen_slider * LimitScale * 0.6;
#endif
}

float getSharpLimitScale() {
	return getSharpLimitMax() - getSharpLimitMin();
}

// Get luma from RGB
float getY(vec3 rgba) {
#if NIS_HDR_MODE == 2
	return 0.262 * rgba.r + 0.678 * rgba.g + 0.0593 * rgba.b;
#elif NIS_HDR_MODE == 1
	return sqrt(0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b) * kHDRCompressionFactor;
#else
	return 0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b;
#endif
}

// Edge detection
vec4 GetEdgeMap(float p[5][5], int i, int j) {
	float g_0 = abs(p[0 + i][0 + j] + p[0 + i][1 + j] + p[0 + i][2 + j] - p[2 + i][0 + j] - p[2 + i][1 + j] - p[2 + i][2 + j]);
	float g_45 = abs(p[1 + i][0 + j] + p[0 + i][0 + j] + p[0 + i][1 + j] - p[2 + i][1 + j] - p[2 + i][2 + j] - p[1 + i][2 + j]);
	float g_90 = abs(p[0 + i][0 + j] + p[1 + i][0 + j] + p[2 + i][0 + j] - p[0 + i][2 + j] - p[1 + i][2 + j] - p[2 + i][2 + j]);
	float g_135 = abs(p[1 + i][0 + j] + p[2 + i][0 + j] + p[2 + i][1 + j] - p[0 + i][1 + j] - p[0 + i][2 + j] - p[1 + i][2 + j]);

	float g_0_90_max = max(g_0, g_90);
	float g_0_90_min = min(g_0, g_90);
	float g_45_135_max = max(g_45, g_135);
	float g_45_135_min = min(g_45, g_135);

	float e_0_90 = 0.0;
	float e_45_135 = 0.0;

	if (g_0_90_max + g_45_135_max == 0.0) {
		return vec4(0.0);
	}

	e_0_90 = min(g_0_90_max / (g_0_90_max + g_45_135_max), 1.0);
	e_45_135 = 1.0 - e_0_90;

	float kDetectRatio = getDetectRatio();
	float kDetectThres = getDetectThres();

	bool c_0_90 = (g_0_90_max > (g_0_90_min * kDetectRatio)) && (g_0_90_max > kDetectThres) && (g_0_90_max > g_45_135_min);
	bool c_45_135 = (g_45_135_max > (g_45_135_min * kDetectRatio)) && (g_45_135_max > kDetectThres) && (g_45_135_max > g_0_90_min);
	bool c_g_0_90 = g_0_90_max == g_0;
	bool c_g_45_135 = g_45_135_max == g_45;

	float f_e_0_90 = (c_0_90 && c_45_135) ? e_0_90 : 1.0;
	float f_e_45_135 = (c_0_90 && c_45_135) ? e_45_135 : 1.0;

	float weight_0 = (c_0_90 && c_g_0_90) ? f_e_0_90 : 0.0;
	float weight_90 = (c_0_90 && !c_g_0_90) ? f_e_0_90 : 0.0;
	float weight_45 = (c_45_135 && c_g_45_135) ? f_e_45_135 : 0.0;
	float weight_135 = (c_45_135 && !c_g_45_135) ? f_e_45_135 : 0.0;

	return vec4(weight_0, weight_90, weight_45, weight_135);
}

// LTI calculation for ringing reduction
float CalcLTIFast(float y[5]) {
	float kEps = 1.0 / 255.0;
	float kMinContrastRatio = getMinContrastRatio();
	float kRatioNorm = getRatioNorm();
	float kContrastBoost = 1.0;

	float a_min = min(min(y[0], y[1]), y[2]);
	float a_max = max(max(y[0], y[1]), y[2]);

	float b_min = min(min(y[2], y[3]), y[4]);
	float b_max = max(max(y[2], y[3]), y[4]);

	float a_cont = a_max - a_min;
	float b_cont = b_max - b_min;

	float cont_ratio = max(a_cont, b_cont) / (min(a_cont, b_cont) + kEps);
	return (1.0 - clamp((cont_ratio - kMinContrastRatio) * kRatioNorm, 0.0, 1.0)) * kContrastBoost;
}

// USM evaluation
float EvalUSM(float pxl[5], float sharpnessStrength, float sharpnessLimit) {
	// USM profile
	float y_usm = -0.6001 * pxl[1] + 1.2002 * pxl[2] - 0.6001 * pxl[3];
	// boost USM profile
	y_usm *= sharpnessStrength;
	// clamp to the limit
	y_usm = min(sharpnessLimit, max(-sharpnessLimit, y_usm));
	// reduce ringing
	y_usm *= CalcLTIFast(pxl);

	return y_usm;
}

// Get directional USM values
vec4 GetDirUSM(float p[5][5]) {
	float kSharpStartY = getSharpStartY();
	float kSharpScaleY = getSharpScaleY();
	float kSharpStrengthMin = getSharpStrengthMin();
	float kSharpStrengthScale = getSharpStrengthScale();
	float kSharpLimitMin = getSharpLimitMin();
	float kSharpLimitScale = getSharpLimitScale();

	float scaleY = 1.0 - clamp((p[2][2] - kSharpStartY) * kSharpScaleY, 0.0, 1.0);
	float sharpnessStrength = scaleY * kSharpStrengthScale + kSharpStrengthMin;
	float sharpnessLimit = (scaleY * kSharpLimitScale + kSharpLimitMin) * p[2][2];

	vec4 rval;

	// 0 deg filter
	float interp0Deg[5];
	for (int i = 0; i < 5; ++i) {
		interp0Deg[i] = p[i][2];
	}
	rval.x = EvalUSM(interp0Deg, sharpnessStrength, sharpnessLimit);

	// 90 deg filter
	float interp90Deg[5];
	for (int i = 0; i < 5; ++i) {
		interp90Deg[i] = p[2][i];
	}
	rval.y = EvalUSM(interp90Deg, sharpnessStrength, sharpnessLimit);

	// 45 deg filter
	float interp45Deg[5];
	interp45Deg[0] = p[1][1];
	interp45Deg[1] = mix(p[2][1], p[1][2], 0.5);
	interp45Deg[2] = p[2][2];
	interp45Deg[3] = mix(p[3][2], p[2][3], 0.5);
	interp45Deg[4] = p[3][3];
	rval.z = EvalUSM(interp45Deg, sharpnessStrength, sharpnessLimit);

	// 135 deg filter
	float interp135Deg[5];
	interp135Deg[0] = p[3][1];
	interp135Deg[1] = mix(p[3][2], p[2][1], 0.5);
	interp135Deg[2] = p[2][2];
	interp135Deg[3] = mix(p[2][3], p[1][2], 0.5);
	interp135Deg[4] = p[1][3];
	rval.w = EvalUSM(interp135Deg, sharpnessStrength, sharpnessLimit);

	return rval;
}

void hook() {

	ivec2 blockIdx = ivec2(gl_WorkGroupID.xy);
	uint threadIdx = gl_LocalInvocationIndex;

	int dstBlockX = NIS_BLOCK_WIDTH * blockIdx.x;
	int dstBlockY = NIS_BLOCK_HEIGHT * blockIdx.y;

	// Fill in input luma tile in batches of 2x2 pixels
	float kShift = 0.5 - float(kSupportSize) / 2.0;

	for (int i = int(threadIdx) * 2; i < kNumPixelsX * kNumPixelsY / 2; i += NIS_THREAD_GROUP_SIZE * 2) {
		uvec2 pos = uvec2(uint(i) % uint(kNumPixelsX), uint(i) / uint(kNumPixelsX) * 2u);
		for (int dy = 0; dy < 2; dy++) {
			for (int dx = 0; dx < 2; dx++) {
				float tx = (float(dstBlockX) + float(pos.x) + float(dx) + kShift) * HOOKED_pt.x;
				float ty = (float(dstBlockY) + float(pos.y) + float(dy) + kShift) * HOOKED_pt.y;
				vec4 px = HOOKED_tex(vec2(tx, ty));
				shPixelsY[pos.y + uint(dy)][pos.x + uint(dx)] = getY(px.rgb);
			}
		}
	}

	barrier();

	for (int k = int(threadIdx); k < NIS_BLOCK_WIDTH * NIS_BLOCK_HEIGHT; k += NIS_THREAD_GROUP_SIZE) {
		ivec2 pos = ivec2(uint(k) % uint(NIS_BLOCK_WIDTH), uint(k) / uint(NIS_BLOCK_WIDTH));

		// Load 5x5 support to regs
		float p[5][5];
		for (int i = 0; i < 5; ++i) {
			for (int j = 0; j < 5; ++j) {
				p[i][j] = shPixelsY[pos.y + i][pos.x + j];
			}
		}

		// Get directional filter bank output
		vec4 dirUSM = GetDirUSM(p);

		// Generate weights for directional filters
		vec4 w = GetEdgeMap(p, kSupportSize / 2 - 1, kSupportSize / 2 - 1);

		// Final USM is a weighted sum of filter outputs
		float usmY = dirUSM.x * w.x + dirUSM.y * w.y + dirUSM.z * w.z + dirUSM.w * w.w;

		// Do bilinear tap and correct rgb texel so it produces new sharpened luma
		int dstX = dstBlockX + pos.x;
		int dstY = dstBlockY + pos.y;

		vec2 coord = vec2((float(dstX) + 0.5) * HOOKED_pt.x, (float(dstY) + 0.5) * HOOKED_pt.y);

		// Bounds check
		if (dstX >= int(HOOKED_size.x) || dstY >= int(HOOKED_size.y)) {
			continue;
		}

		vec4 op = HOOKED_tex(coord);

#if NIS_HDR_MODE == 1
		float kEps = 1e-4 * kHDRCompressionFactor * kHDRCompressionFactor;
		float newY = p[2][2] + usmY;
		newY = max(newY, 0.0);
		float oldY = p[2][2];
		float corr = (newY * newY + kEps) / (oldY * oldY + kEps);
		op.rgb *= corr;
#else
		op.rgb += usmY;
#endif

		op = clamp(op, 0.0, 1.0);
		imageStore(out_image, ivec2(dstX, dstY), op);
	}

}

