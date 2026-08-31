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
//!BIND coef_scaler_fp16
//!BIND coef_usm_fp16
//!BIND coef_scaler
//!BIND coef_usm
//!DESC [NVScaler_RT] (SDK v1.0.3)
//!WIDTH OUTPUT.w
//!HEIGHT OUTPUT.h
//!WHEN OUTPUT.w HOOKED.w 1.0 * > OUTPUT.h HOOKED.h 1.0 * > *
//!COMPUTE 32 24 256 1

#define FP16   1

// Constants
#define kPhaseCount 64
#define kFilterSize 6
#define kSupportSize 6
#define kPadSize 6
#define NIS_BLOCK_WIDTH 32
#define NIS_BLOCK_HEIGHT 24
#define NIS_THREAD_GROUP_SIZE 256

#define kTilePitch (NIS_BLOCK_WIDTH + kPadSize)
#define kTileSize (kTilePitch * (NIS_BLOCK_HEIGHT + kPadSize))
#define kEdgeMapPitch (NIS_BLOCK_WIDTH + 2)
#define kEdgeMapSize (kEdgeMapPitch * (NIS_BLOCK_HEIGHT + 2))

#define kHDRCompressionFactor 0.282842712

shared float shPixelsY[kTileSize];
shared float shCoefScaler[kPhaseCount][kFilterSize];
shared float shCoefUSM[kPhaseCount][kFilterSize];
shared vec4 shEdgeMap[kEdgeMapSize];

// Sharpness (computed from SHARP)
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

float getY(vec3 rgba) {
#if NIS_HDR_MODE == 2
	return 0.262 * rgba.r + 0.678 * rgba.g + 0.0593 * rgba.b;
#elif NIS_HDR_MODE == 1
	return sqrt(0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b) * kHDRCompressionFactor;
#else
	return 0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b;
#endif
}

float getYLinear(vec3 rgba) {
	return 0.2126 * rgba.r + 0.7152 * rgba.g + 0.0722 * rgba.b;
}

vec4 GetEdgeMap(float p[4][4], int i, int j) {
	float kDetectRatio = getDetectRatio();
	float kDetectThres = getDetectThres();

	float g_0 = abs(p[0 + i][0 + j] + p[0 + i][1 + j] + p[0 + i][2 + j] - p[2 + i][0 + j] - p[2 + i][1 + j] - p[2 + i][2 + j]);
	float g_45 = abs(p[1 + i][0 + j] + p[0 + i][0 + j] + p[0 + i][1 + j] - p[2 + i][1 + j] - p[2 + i][2 + j] - p[1 + i][2 + j]);
	float g_90 = abs(p[0 + i][0 + j] + p[1 + i][0 + j] + p[2 + i][0 + j] - p[0 + i][2 + j] - p[1 + i][2 + j] - p[2 + i][2 + j]);
	float g_135 = abs(p[1 + i][0 + j] + p[2 + i][0 + j] + p[2 + i][1 + j] - p[0 + i][1 + j] - p[0 + i][2 + j] - p[1 + i][2 + j]);

	float g_0_90_max = max(g_0, g_90);
	float g_0_90_min = min(g_0, g_90);
	float g_45_135_max = max(g_45, g_135);
	float g_45_135_min = min(g_45, g_135);

	if (g_0_90_max + g_45_135_max == 0.0) {
		return vec4(0.0);
	}

	float e_0_90 = min(g_0_90_max / (g_0_90_max + g_45_135_max), 1.0);
	float e_45_135 = 1.0 - e_0_90;

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

void LoadFilterBanksSh(int i0) {
	int i = i0;
	if (i < kPhaseCount * 2) {
		int phase = i >> 1;
		int vIdx = i & 1;

#if FP16
		vec4 v = texelFetch(coef_scaler_fp16, ivec2(vIdx, phase), 0);
#else
		vec4 v = texelFetch(coef_scaler, ivec2(vIdx, phase), 0);
#endif
		int filterOffset = vIdx * 4;
		shCoefScaler[phase][filterOffset + 0] = v.x;
		shCoefScaler[phase][filterOffset + 1] = v.y;
		if (vIdx == 0) {
			shCoefScaler[phase][2] = v.z;
			shCoefScaler[phase][3] = v.w;
		}

#if FP16
		v = texelFetch(coef_usm_fp16, ivec2(vIdx, phase), 0);
#else
		v = texelFetch(coef_usm, ivec2(vIdx, phase), 0);
#endif
		shCoefUSM[phase][filterOffset + 0] = v.x;
		shCoefUSM[phase][filterOffset + 1] = v.y;
		if (vIdx == 0) {
			shCoefUSM[phase][2] = v.z;
			shCoefUSM[phase][3] = v.w;
		}
	}
}

float CalcLTI(float p0, float p1, float p2, float p3, float p4, float p5, int phase_index) {
	float kEps = 1.0 / 255.0;
	float kMinContrastRatio = getMinContrastRatio();
	float kRatioNorm = getRatioNorm();
	float kContrastBoost = 1.0;

	bool selector = (phase_index <= kPhaseCount / 2);
	float sel = selector ? p0 : p3;
	float a_min = min(min(p1, p2), sel);
	float a_max = max(max(p1, p2), sel);
	sel = selector ? p2 : p5;
	float b_min = min(min(p3, p4), sel);
	float b_max = max(max(p3, p4), sel);

	float a_cont = a_max - a_min;
	float b_cont = b_max - b_min;

	float cont_ratio = max(a_cont, b_cont) / (min(a_cont, b_cont) + kEps);
	return (1.0 - clamp((cont_ratio - kMinContrastRatio) * kRatioNorm, 0.0, 1.0)) * kContrastBoost;
}

vec4 GetInterpEdgeMap(vec4 edge[2][2], float phase_frac_x, float phase_frac_y) {
	vec4 h0 = mix(edge[0][0], edge[0][1], phase_frac_x);
	vec4 h1 = mix(edge[1][0], edge[1][1], phase_frac_x);
	return mix(h0, h1, phase_frac_y);
}

float EvalPoly6(float pxl[6], int phase_int) {
	float kSharpStartY = getSharpStartY();
	float kSharpScaleY = getSharpScaleY();
	float kSharpStrengthMin = getSharpStrengthMin();
	float kSharpStrengthScale = getSharpStrengthScale();
	float kSharpLimitMin = getSharpLimitMin();
	float kSharpLimitScale = getSharpLimitScale();

	float y = 0.0;
	for (int i = 0; i < 6; ++i) {
		y += shCoefScaler[phase_int][i] * pxl[i];
	}

	float y_usm = 0.0;
	for (int i = 0; i < 6; ++i) {
		y_usm += shCoefUSM[phase_int][i] * pxl[i];
	}

	float y_scale = 1.0 - clamp((y - kSharpStartY) * kSharpScaleY, 0.0, 1.0);
	float y_sharpness = y_scale * kSharpStrengthScale + kSharpStrengthMin;
	y_usm *= y_sharpness;

	float y_sharpness_limit = (y_scale * kSharpLimitScale + kSharpLimitMin) * y;
	y_usm = min(y_sharpness_limit, max(-y_sharpness_limit, y_usm));
	y_usm *= CalcLTI(pxl[0], pxl[1], pxl[2], pxl[3], pxl[4], pxl[5], phase_int);

	return y + y_usm;
}

float FilterNormal(float p[6][6], int phase_x_frac_int, int phase_y_frac_int) {
	float h_acc = 0.0;
	for (int j = 0; j < 6; ++j) {
		float v_acc = 0.0;
		for (int i = 0; i < 6; ++i) {
			v_acc += p[i][j] * shCoefScaler[phase_y_frac_int][i];
		}
		h_acc += v_acc * shCoefScaler[phase_x_frac_int][j];
	}
	return h_acc;
}

float AddDirFilters(float p[6][6], float phase_x_frac, float phase_y_frac, int phase_x_frac_int, int phase_y_frac_int, vec4 w) {
	float f = 0.0;

	if (w.x > 0.0) {
		float interp0Deg[6];
		for (int i = 0; i < 6; ++i) {
			interp0Deg[i] = mix(p[i][2], p[i][3], phase_x_frac);
		}
		f += EvalPoly6(interp0Deg, phase_y_frac_int) * w.x;
	}

	if (w.y > 0.0) {
		float interp90Deg[6];
		for (int i = 0; i < 6; ++i) {
			interp90Deg[i] = mix(p[2][i], p[3][i], phase_y_frac);
		}
		f += EvalPoly6(interp90Deg, phase_x_frac_int) * w.y;
	}

	if (w.z > 0.0) {
		float pphase_b45 = 0.5 + 0.5 * (phase_x_frac - phase_y_frac);

		float temp_interp45Deg[7];
		temp_interp45Deg[1] = mix(p[2][1], p[1][2], pphase_b45);
		temp_interp45Deg[3] = mix(p[3][2], p[2][3], pphase_b45);
		temp_interp45Deg[5] = mix(p[4][3], p[3][4], pphase_b45);

		float pb45 = pphase_b45 - 0.5;
		float a = (pb45 >= 0.0) ? p[0][2] : p[2][0];
		float b = (pb45 >= 0.0) ? p[1][3] : p[3][1];
		float c = (pb45 >= 0.0) ? p[2][4] : p[4][2];
		float d = (pb45 >= 0.0) ? p[3][5] : p[5][3];
		temp_interp45Deg[0] = mix(p[1][1], a, abs(pb45));
		temp_interp45Deg[2] = mix(p[2][2], b, abs(pb45));
		temp_interp45Deg[4] = mix(p[3][3], c, abs(pb45));
		temp_interp45Deg[6] = mix(p[4][4], d, abs(pb45));

		float interp45Deg[6];
		float pphase_p45 = phase_x_frac + phase_y_frac;
		if (pphase_p45 >= 1.0) {
			for (int i = 0; i < 6; i++) {
				interp45Deg[i] = temp_interp45Deg[i + 1];
			}
			pphase_p45 = pphase_p45 - 1.0;
		} else {
			for (int i = 0; i < 6; i++) {
				interp45Deg[i] = temp_interp45Deg[i];
			}
		}
		f += EvalPoly6(interp45Deg, int(pphase_p45 * 64.0)) * w.z;
	}

	if (w.w > 0.0) {
		float pphase_b135 = 0.5 * (phase_x_frac + phase_y_frac);

		float temp_interp135Deg[7];
		temp_interp135Deg[1] = mix(p[3][1], p[4][2], pphase_b135);
		temp_interp135Deg[3] = mix(p[2][2], p[3][3], pphase_b135);
		temp_interp135Deg[5] = mix(p[1][3], p[2][4], pphase_b135);

		float pb135 = pphase_b135 - 0.5;
		float a = (pb135 >= 0.0) ? p[5][2] : p[3][0];
		float b = (pb135 >= 0.0) ? p[4][3] : p[2][1];
		float c = (pb135 >= 0.0) ? p[3][4] : p[1][2];
		float d = (pb135 >= 0.0) ? p[2][5] : p[0][3];
		temp_interp135Deg[0] = mix(p[4][1], a, abs(pb135));
		temp_interp135Deg[2] = mix(p[3][2], b, abs(pb135));
		temp_interp135Deg[4] = mix(p[2][3], c, abs(pb135));
		temp_interp135Deg[6] = mix(p[1][4], d, abs(pb135));

		float interp135Deg[6];
		float pphase_p135 = 1.0 + (phase_x_frac - phase_y_frac);
		if (pphase_p135 >= 1.0) {
			for (int i = 0; i < 6; ++i) {
				interp135Deg[i] = temp_interp135Deg[i + 1];
			}
			pphase_p135 = pphase_p135 - 1.0;
		} else {
			for (int i = 0; i < 6; ++i) {
				interp135Deg[i] = temp_interp135Deg[i];
			}
		}
		f += EvalPoly6(interp135Deg, int(pphase_p135 * 64.0)) * w.w;
	}

	return f;
}

void hook() {

	ivec2 blockIdx = ivec2(gl_WorkGroupID.xy);
	uint threadIdx = gl_LocalInvocationIndex;

	float kScaleX = HOOKED_size.x / target_size.x;
	float kScaleY = HOOKED_size.y / target_size.y;

	int dstBlockX = NIS_BLOCK_WIDTH * blockIdx.x;
	int dstBlockY = NIS_BLOCK_HEIGHT * blockIdx.y;

	// Calculate source block bounds
	int srcBlockStartX = int(floor((float(dstBlockX) + 0.5) * kScaleX - 0.5));
	int srcBlockStartY = int(floor((float(dstBlockY) + 0.5) * kScaleY - 0.5));
	int srcBlockEndX = int(ceil((float(dstBlockX + NIS_BLOCK_WIDTH) + 0.5) * kScaleX - 0.5));
	int srcBlockEndY = int(ceil((float(dstBlockY + NIS_BLOCK_HEIGHT) + 0.5) * kScaleY - 0.5));

	int numTilePixelsX = srcBlockEndX - srcBlockStartX + kSupportSize - 1;
	int numTilePixelsY = srcBlockEndY - srcBlockStartY + kSupportSize - 1;

	numTilePixelsX += numTilePixelsX & 1;
	numTilePixelsY += numTilePixelsY & 1;
	int numTilePixels = numTilePixelsX * numTilePixelsY;

	int numEdgeMapPixelsX = numTilePixelsX - kSupportSize + 2;
	int numEdgeMapPixelsY = numTilePixelsY - kSupportSize + 2;
	int numEdgeMapPixels = numEdgeMapPixelsX * numEdgeMapPixelsY;

	// Load luma tile into shared memory
	// Shift by -2.0 to center the 6-tap filter support (filter taps at -2.5, -1.5, -0.5, 0.5, 1.5, 2.5)
	for (uint i = threadIdx * 2u; i < uint(numTilePixels) >> 1; i += NIS_THREAD_GROUP_SIZE * 2u) {
		uint py = (i / uint(numTilePixelsX)) * 2u;
		uint px = i % uint(numTilePixelsX);

		float kShift = -2.0;  // Center of 6-tap filter
		float srcX = float(srcBlockStartX) + float(px) + kShift;
		float srcY = float(srcBlockStartY) + float(py) + kShift;

		float p[2][2];
#ifdef HOOKED_gather
		{
			float ksrcX = (float(srcBlockStartX) + float(px) + kShift + 0.5) * HOOKED_pt.x;
			float ksrcY = (float(srcBlockStartY) + float(py) + kShift + 0.5) * HOOKED_pt.y;
			vec4 sr = HOOKED_gather(vec2(ksrcX, ksrcY), 0);
			vec4 sg = HOOKED_gather(vec2(ksrcX, ksrcY), 1);
			vec4 sb = HOOKED_gather(vec2(ksrcX, ksrcY), 2);

			p[0][0] = getY(vec3(sr.w, sg.w, sb.w));
			p[0][1] = getY(vec3(sr.z, sg.z, sb.z));
			p[1][0] = getY(vec3(sr.x, sg.x, sb.x));
			p[1][1] = getY(vec3(sr.y, sg.y, sb.y));
		}
#else
		for (int j = 0; j < 2; j++) {
			for (int k = 0; k < 2; k++) {
				// Convert to normalized texture coordinates with 0.5 texel center offset
				float tx = (srcX + float(k) + 0.5) * HOOKED_pt.x;
				float ty = (srcY + float(j) + 0.5) * HOOKED_pt.y;
				vec4 px_color = HOOKED_tex(vec2(tx, ty));
				p[j][k] = getY(px_color.rgb);
			}
		}
#endif
		uint idx = py * uint(kTilePitch) + px;
		shPixelsY[idx] = p[0][0];
		shPixelsY[idx + 1u] = p[0][1];
		shPixelsY[idx + uint(kTilePitch)] = p[1][0];
		shPixelsY[idx + uint(kTilePitch) + 1u] = p[1][1];
	}

	barrier();

	// Compute edge map
	for (uint i = threadIdx * 2u; i < uint(numEdgeMapPixels) >> 1; i += NIS_THREAD_GROUP_SIZE * 2u) {
		uint py = (i / uint(numEdgeMapPixelsX)) * 2u;
		uint px = i % uint(numEdgeMapPixelsX);

		uint edgeMapIdx = py * uint(kEdgeMapPitch) + px;
		uint tileCornerIdx = (py + 1u) * uint(kTilePitch) + px + 1u;

		float p[4][4];
		for (int j = 0; j < 4; j++) {
			for (int k = 0; k < 4; k++) {
				p[j][k] = shPixelsY[tileCornerIdx + uint(j) * uint(kTilePitch) + uint(k)];
			}
		}

		shEdgeMap[edgeMapIdx] = GetEdgeMap(p, 0, 0);
		shEdgeMap[edgeMapIdx + 1u] = GetEdgeMap(p, 0, 1);
		shEdgeMap[edgeMapIdx + uint(kEdgeMapPitch)] = GetEdgeMap(p, 1, 0);
		shEdgeMap[edgeMapIdx + uint(kEdgeMapPitch) + 1u] = GetEdgeMap(p, 1, 1);
	}

	LoadFilterBanksSh(int(threadIdx));
	barrier();

	ivec2 pos = ivec2(uint(threadIdx) % uint(NIS_BLOCK_WIDTH), uint(threadIdx) / uint(NIS_BLOCK_WIDTH));
	int dstX = dstBlockX + pos.x;
	float srcX = (0.5 + float(dstX)) * kScaleX - 0.5;
	int px_pos = int(floor(srcX) - float(srcBlockStartX));
	float fx = srcX - floor(srcX);
	int fx_int = int(fx * float(kPhaseCount));

	for (int k = 0; k < NIS_BLOCK_WIDTH * NIS_BLOCK_HEIGHT / NIS_THREAD_GROUP_SIZE; ++k) {
		int dstY = dstBlockY + pos.y + k * (NIS_THREAD_GROUP_SIZE / NIS_BLOCK_WIDTH);
		float srcY = (0.5 + float(dstY)) * kScaleY - 0.5;

		int py_pos = int(floor(srcY) - float(srcBlockStartY));
		float fy = srcY - floor(srcY);
		int fy_int = int(fy * float(kPhaseCount));

		int startEdgeMapIdx = py_pos * kEdgeMapPitch + px_pos;
		vec4 edge[2][2];
		for (int i = 0; i < 2; i++) {
			for (int j = 0; j < 2; j++) {
				edge[i][j] = shEdgeMap[startEdgeMapIdx + i * kEdgeMapPitch + j];
			}
		}
		vec4 w = GetInterpEdgeMap(edge, fx, fy);

		int startTileIdx = py_pos * kTilePitch + px_pos;
		float p[6][6];
		for (int i = 0; i < 6; ++i) {
			for (int j = 0; j < 6; ++j) {
				p[i][j] = shPixelsY[startTileIdx + i * kTilePitch + j];
			}
		}

		float baseWeight = 1.0 - w.x - w.y - w.z - w.w;

		float opY = 0.0;
		opY += FilterNormal(p, fx_int, fy_int) * baseWeight;
		opY += AddDirFilters(p, fx, fy, fx_int, fy_int, w);

		// Sample the source at the corresponding position
		float srcTexX = (srcX + 0.5) * HOOKED_pt.x;
		float srcTexY = (srcY + 0.5) * HOOKED_pt.y;
		ivec2 dstCoord = ivec2(dstX, dstY);

		if (dstX >= int(target_size.x) || dstY >= int(target_size.y)) {
			continue;
		}

		vec4 op = HOOKED_tex(vec2(srcTexX, srcTexY));
		float y = getY(op.rgb);

#if NIS_HDR_MODE == 1
		float kEps = 1e-4;
		float opYN = max(opY, 0.0) / kHDRCompressionFactor;
		float corr = (opYN * opYN + kEps) / (max(getYLinear(op.rgb), 0.0) + kEps);
		op.rgb *= corr;
#else
		float corr = opY - y;
		op.rgb += corr;
#endif

		op = clamp(op, 0.0, 1.0);
		imageStore(out_image, dstCoord, op);
	}

}

//!TEXTURE coef_scaler_fp16
//!SIZE 2 64
//!FORMAT rgba16hf
//!FILTER NEAREST
00000000003c00000000000000000000
f01981a2003cc222f79a000000000000
741e60a6fd3be326f79e000000000000
81209fa8f73b502946a1191000000000
fe2111aaf23b322b45a3191000000000
45235fabeb3b902ca2a4191000000000
402450ace03b982da2a5191400000000
c324e0acd43ba82ec2a6251600000000
3f2571adc83bb82fe3a7191800000000
c325f0adb83b6c3081a8ea1800000000
1e2670aea93bfc3012a9f01900000000
8126e0ae973b90319fa9f71a00000000
c22648af833b2c323faa811c00000000
1e279faf6d3bc832e0aa051d00000000
5f27f8af563b643370ab0b1e00000000
802724b03f3b043408ac741e00000000
c22744b0243b563458ac7a1f00000000
e32760b0083baa34a9ac402000000000
e3277cb0ed3afe34f7acc32000000000
022890b0ce3a543548ad462100000000
0228a0b0af3aaa3598adbc2100000000
0228acb08e3a0236e8ad3f2200000000
0228b4b06b3a583630ae042300000000
e327bcb0493ab23681ae7a2300000000
c227bcb0253a0a37c9aefd2300000000
a127bcb0013a623711af402400000000
8027b4b0da39ba3757afa22400000000
5f27acb0b2390a3899afdd2400000000
1e27a0b08b393638d9af1f2500000000
fd2694b06139623808b0812500000000
c22684b039398e3828b0c32500000000
812670b00f39b93840b0fe2500000000
3f2658b0e438e43858b03f2600000000
fe2540b0b9380f3970b0812600000000
c32528b08e38393984b0c22600000000
812508b06238613994b0fd2600000000
1f25d9af36388b39a0b01e2700000000
dd2499af0a38b239acb05f2700000000
a22457afba37da39b4b0802700000000
402411af6237013abcb0a12700000000
fd23c9ae0a37253abcb0c22700000000
7a2381aeb236493abcb0e32700000000
042330ae58366b3ab4b0022800000000
3f22e8ad02368e3aacb0022800000000
bc2198adaa35af3aa0b0022800000000
462148ad5435ce3a90b0022800000000
c320f7acfe34ed3a7cb0e32700000000
4020a9acaa34083b60b0e32700000000
7a1f58ac5634243b44b0c22700000000
741e08ac04343f3b24b0802700000000
0b1e70ab6433563bf8af5f2700000000
051de0aac8326d3b9faf1e2700000000
811c3faa2c32833b48afc22600000000
f71a9fa99031973be0ae812600000000
f01912a9fc30a93b70ae1e2600000000
ea1881a86c30b83bf0adc32500000000
1918e3a7b82fc83b71ad3f2500000000
2516c2a6a82ed43be0acc32400000000
1914a2a5982de03b50ac402400000000
1910a2a4902ceb3b5fab452300000000
191045a3322bf23b11aafe2100000000
191046a15029f73b9fa8812000000000
0000f79ee326fd3b60a6741e00000000
0000f79ac222003c81a2f01900000000

//!TEXTURE coef_usm_fp16
//!SIZE 2 64
//!FORMAT rgba16hf
//!FILTER NEAREST
0000cdb8cd3ccdb80000000000000000
f019deb8cb3cb9b8f099000000000000
051debb8c83ca2b8f79e191000000000
7a1ff5b8c23c87b846a1000000000000
c320fdb8b93c69b8bba3000000000000
bc2103b9ae3c48b8fea4191000000000
3f2204b9a23c25b8a1a6191000000000
452307b9953c01b80fa8191000000000
fd2303b9823caab7f1a8191000000000
4024fdb8703c50b7d0a9191400000000
8124f3b85a3cf4b6cfaa191400000000
a224e9b8433c90b6dfab251600000000
dd24dbb8293c26b678ac251600000000
fe24ceb8103cb8b518ad191800000000
1f25beb8ea3b42b5bfadea1800000000
1f25a8b8aa3bc8b468aef01900000000
1f2595b86f3b4eb411aff71a00000000
1f257fb82e3b94b3d9affd1b00000000
3f2566b8ea3a8cb24cb0811c00000000
1f254cb8a43a78b1b0b0051d00000000
fe2431b85b3a60b014b1881d00000000
fe2416b8143a89ae84b10b1e00000000
dd24f2b7c93927acf8b1741e00000000
c324b6b77a395fa764b2f71e00000000
c32478b72b39c320dcb27a1f00000000
812436b7d838222a54b3402000000000
6124feb68e387f2dd4b3812000000000
1f24b8b63a38043028b4052100000000
1f247ab6d0374c3168b4462100000000
bb2338b632378832a8b47a2100000000
4523f0b58436d433e8b4fe2100000000
0423b0b5e03590342ab53f2200000000
c2226eb5383538356eb5c22200000000
3f222ab59034e035b0b5042300000000
fe21e8b4d4338436f0b5452300000000
7a21a8b48832323738b6bb2300000000
462168b44c31d0377ab61f2400000000
052128b404303a38b8b61f2400000000
8120d4b37f2d8e38feb6612400000000
402054b3222ad83836b7812400000000
7a1fdcb2c3202b3978b7c32400000000
f71e64b25fa77a39b6b7c32400000000
741ef8b127acc939f2b7dd2400000000
0b1e84b189ae143a16b8fe2400000000
881d14b160b05b3a31b8fe2400000000
051db0b078b1a43a4cb81f2500000000
811c4cb08cb2ea3a66b83f2500000000
fd1bd9af94b32e3b7fb81f2500000000
f71a11af4eb46f3b95b81f2500000000
f01968aec8b4aa3ba8b81f2500000000
ea18bfad42b5ea3bbeb81f2500000000
191818adb8b5103cceb8fe2400000000
251678ac26b6293cdbb8dd2400000000
2516dfab90b6433ce9b8a22400000000
1914cfaaf4b65a3cf3b8812400000000
1914d0a950b7703cfdb8402400000000
1910f1a8aab7823c03b9fd2300000000
19100fa801b8953c07b9452300000000
1910a1a625b8a23c04b93f2200000000
1910fea448b8ae3c03b9bc2100000000
0000bba369b8b93cfdb8c32000000000
000046a187b8c23cf5b87a1f00000000
1910f79ea2b8c83cebb8051d00000000
0000f099b9b8cb3cdeb8f01900000000

//!TEXTURE coef_scaler
//!SIZE 2 64
//!FORMAT rgba32f
//!FILTER NEAREST
00000000000000000000803f0000000000000000000000000000000000000000
ed0d3e3ba91350bc0000803fd044583c89d25ebb000000000000000000000000
3b70ce3b16fbcbbcb29d7f3f645ddc3c89d2debb000000000000000000000000
e02d103c98dd13bda4df7e3fe7fb293d55c128bc6f12033a0000000000000000
5bb13f3c812642bd5b427e3ff931663d1ea768bc6f12033a0000000000000000
1ea7683cfaed6bbdfb5c7d3fbc05923d744694bc6f12033a0000000000000000
b9fc873c03098abda3017c3fc5feb23d5839b4bc6f12833a0000000000000000
075f983cbf0e9cbdfa7e7a3ff4fdd43dd044d8bca69bc43a0000000000000000
9eefa73c7b14aebdde02793f22fdf63d4850fcbc6f12033b0000000000000000
ec51b83ced0dbebd22fd763f4d840d3ee02d10bd52491d3b0000000000000000
efc9c33c5f07cebdb81e753f098a1f3e9c3322bded0d3e3b0000000000000000
a913d03c88f4dbbd01de723fa1f8313e7dd033bd89d25e3b0000000000000000
d044d83cf90fe9bd4e62703f9487453e82e247bde02d903b0000000000000000
d3bce33cb3eaf3bd849e6d3f50fc583e88f45bbd2e90a03b0000000000000000
faedeb3cdbf9febd83c06a3f448b6c3e44fa6dbdca54c13b0000000000000000
8e06f03c6f8104be82e2673f1283803e250681bd3b70ce3b0000000000000000
b537f83ccc7f08be6f81643f83c08a3e280f8bbdd734ef3b0000000000000000
4850fc3c16fb0bbe97ff603f7d3f953e2b1895bdb9fc073c0000000000000000
4850fc3c60760fbe849e5d3f77be9f3ec0ec9ebd075f183c0000000000000000
6e34003dbc0512beecc0593ffa7eaa3ec3f5a8bd55c1283c0000000000000000
6e34003dcff713bec6dc553f7d3fb53ec5feb2bd3480373c0000000000000000
6e34003d068115bea5bd513f8941c03ec807bdbd82e2473c0000000000000000
6e34003d2b8716befb5c4d3f0c02cb3ea60ac6bdf775603c0000000000000000
4850fc3c197317be151d493fa245d63ea913d0bdd7346f3c0000000000000000
b537f83c197317be34a2443f933ae13e8716d9bd24977f3c0000000000000000
211ff43c197317bec520403f9f3cec3e6519e2bdb9fc873c0000000000000000
8e06f03c2b8716be083d3b3fab3ef73ed5e7eabd7446943c0000000000000000
faedeb3c068115be143f363f2041013ffc18f3bde3a59b3c0000000000000000
d3bce33ccff713bee561313f27c2063fb515fbbd0ad7a33c0000000000000000
40a4df3cce8812be68222c3f2d430c3f250601bec520b03c0000000000000000
d044d83c857c10bee71d273fa5bd113f810405beec51b83c0000000000000000
a913d03c5f070ebe6ade213fe71d173fb9fc07be5bb1bf3c0000000000000000
82e2c73cf1f40abe287e1c3f287e1c3ff1f40abe82e2c73c0000000000000000
5bb1bf3cb9fc07bee71d173f6ade213f5f070ebea913d03c0000000000000000
ec51b83c810405bea5bd113fe71d273f857c10bed044d83c0000000000000000
c520b03c250601be2d430c3f68222c3fce8812be40a4df3c0000000000000000
0ad7a33cb515fbbd27c2063fe561313fcff713bed3bce33c0000000000000000
e3a59b3cfc18f3bd2041013f143f363f068115befaedeb3c0000000000000000
7446943cd5e7eabdab3ef73e083d3b3f2b8716be8e06f03c0000000000000000
b9fc873c6519e2bd9f3cec3ec520403f197317be211ff43c0000000000000000
24977f3c8716d9bd933ae13e34a2443f197317beb537f83c0000000000000000
d7346f3ca913d0bda245d63e151d493f197317be4850fc3c0000000000000000
f775603ca60ac6bd0c02cb3efb5c4d3f2b8716be6e34003d0000000000000000
82e2473cc807bdbd8941c03ea5bd513f068115be6e34003d0000000000000000
3480373cc5feb2bd7d3fb53ec6dc553fcff713be6e34003d0000000000000000
55c1283cc3f5a8bdfa7eaa3eecc0593fbc0512be6e34003d0000000000000000
075f183cc0ec9ebd77be9f3e849e5d3f60760fbe4850fc3c0000000000000000
b9fc073c2b1895bd7d3f953e97ff603f16fb0bbe4850fc3c0000000000000000
d734ef3b280f8bbd83c08a3e6f81643fcc7f08beb537f83c0000000000000000
3b70ce3b250681bd1283803e82e2673f6f8104be8e06f03c0000000000000000
ca54c13b44fa6dbd448b6c3e83c06a3fdbf9febdfaedeb3c0000000000000000
2e90a03b88f45bbd50fc583e849e6d3fb3eaf3bdd3bce33c0000000000000000
e02d903b82e247bd9487453e4e62703ff90fe9bdd044d83c0000000000000000
89d25e3b7dd033bda1f8313e01de723f88f4dbbda913d03c0000000000000000
ed0d3e3b9c3322bd098a1f3eb81e753f5f07cebdefc9c33c0000000000000000
52491d3be02d10bd4d840d3e22fd763fed0dbebdec51b83c0000000000000000
6f12033b4850fcbc22fdf63dde02793f7b14aebd9eefa73c0000000000000000
a69bc43ad044d8bcf4fdd43dfa7e7a3fbf0e9cbd075f983c0000000000000000
6f12833a5839b4bcc5feb23da3017c3f03098abdb9fc873c0000000000000000
6f12033a744694bcbc05923dfb5c7d3ffaed6bbd1ea7683c0000000000000000
6f12033a1ea768bcf931663d5b427e3f812642bd5bb13f3c0000000000000000
6f12033a55c128bce7fb293da4df7e3f98dd13bde02d103c0000000000000000
0000000089d2debb645ddc3cb29d7f3f16fbcbbc3b70ce3b0000000000000000
0000000089d25ebbd044583c0000803fa91350bced0d3e3b0000000000000000

//!TEXTURE coef_usm
//!SIZE 2 64
//!FORMAT rgba32f
//!FILTER NEAREST
0000000027a019bf27a0993f27a019bf00000000000000000000000000000000
ed0d3e3b1ac01bbf006f993fe71d17bfed0d3ebb000000000000000000000000
2e90a03bfb5c1dbff90f993fe63f14bf89d2debb6f12033a0000000000000000
d734ef3b1b9e1ebf2731983fd3de10bf55c128bc000000000000000000000000
075f183cb29d1fbfcb10973fff210dbffe6577bc000000000000000000000000
3480373c4e6220bf48bf953fde0209bf77be9fbc6f12033a0000000000000000
82e2473c128320bfe63f943f34a204bf3d2cd4bc6f12033a0000000000000000
1ea7683cd3de20bfbe9f923fc52000bfdcd701bd6f12033a0000000000000000
24977f3c4e6220bfa54e903f7d3ff5be091b1ebd6f12033a0000000000000000
b9fc873cb29d1fbf6ff08d3fe7fbe9be5af539bd6f12833a0000000000000000
e02d903c20631ebf4f408b3fe483debe3ee859bd6f12833a0000000000000000
7446943cff211dbf696f883fbc05d2be6de77bbda69bc43a0000000000000000
e3a59b3ccc5d1bbf1b2f853ff8c2c4be4df38ebda69bc43a0000000000000000
77be9f3cecc019bf910f823f22fdb6be5305a3bd6f12033b0000000000000000
0ad7a33cbec117bfc4427d3f423ea8be10e9b7bd52491d3b0000000000000000
0ad7a33cf4fd14bf7d3f753f50fc98be3b01cdbded0d3e3b0000000000000000
0ad7a33c05a312bf0de06d3f5eba89be6519e2bd89d25e3b0000000000000000
0ad7a33c3bdf0fbf8fc2653fb37b72beb515fbbd24977f3b0000000000000000
9eefa73cb1bf0cbfc4425d3faa8251bef08509bee02d903b0000000000000000
0ad7a33c637f09bf6f81543f69002fbe190416be2e90a03b0000000000000000
77be9f3c4f1e06bfcc5d4b3f16fb0bbe418222be7cf2b03b0000000000000000
77be9f3c3cbd02bf4182423fce19d1bda08930beca54c13b0000000000000000
e3a59b3c5b42febe151d393f4bea84bddbf93ebe3b70ce3b0000000000000000
075f983c99bbf6bef2412f3ffaedebbc287e4cbe89d2de3b0000000000000000
075f983c6900efbe4260253f075f183cac8b5bbed734ef3b0000000000000000
e02d903c27c2e6be0c021b3fca32443dfa7e6abeb9fc073c0000000000000000
4d158c3c77bedfbea5bd113f57ecaf3d6c787abee02d103c0000000000000000
26e4833c22fdd6beab3e073f1283003e810485be2e90203c0000000000000000
26e4833cf241cfbe7502fa3ed578293e3b018dbe55c1283c0000000000000000
fe65773cb003c7be143fe63e97ff503ef4fd94be0e4f2f3c0000000000000000
1ea7683cd200bebe857cd03e6c787a3eadfa9cbe5bb13f3c0000000000000000
f775603c1904b6bea301bc3ebc05923e0b46a5be82e2473c0000000000000000
d044583cd6c5adbeb003a73eb003a73ed6c5adbed044583c0000000000000000
82e2473c0b46a5bebc05923ea301bc3e1904b6bef775603c0000000000000000
5bb13f3cadfa9cbe6c787a3e857cd03ed200bebe1ea7683c0000000000000000
0e4f2f3cf4fd94be97ff503e143fe63eb003c7befe65773c0000000000000000
55c1283c3b018dbed578293e7502fa3ef241cfbe26e4833c0000000000000000
2e90203c810485be1283003eab3e073f22fdd6be26e4833c0000000000000000
e02d103c6c787abe57ecaf3da5bd113f77bedfbe4d158c3c0000000000000000
b9fc073cfa7e6abeca32443d0c021b3f27c2e6bee02d903c0000000000000000
d734ef3bac8b5bbe075f183c4260253f6900efbe075f983c0000000000000000
89d2de3b287e4cbefaedebbcf2412f3f99bbf6be075f983c0000000000000000
3b70ce3bdbf93ebe4bea84bd151d393f5b42febee3a59b3c0000000000000000
ca54c13ba08930bece19d1bd4182423f3cbd02bf77be9f3c0000000000000000
7cf2b03b418222be16fb0bbecc5d4b3f4f1e06bf77be9f3c0000000000000000
2e90a03b190416be69002fbe6f81543f637f09bf0ad7a33c0000000000000000
e02d903bf08509beaa8251bec4425d3fb1bf0cbf9eefa73c0000000000000000
24977f3bb515fbbdb37b72be8fc2653f3bdf0fbf0ad7a33c0000000000000000
89d25e3b6519e2bd5eba89be0de06d3f05a312bf0ad7a33c0000000000000000
ed0d3e3b3b01cdbd50fc98be7d3f753ff4fd14bf0ad7a33c0000000000000000
52491d3b10e9b7bd423ea8bec4427d3fbec117bf0ad7a33c0000000000000000
6f12033b5305a3bd22fdb6be910f823fecc019bf77be9f3c0000000000000000
a69bc43a4df38ebdf8c2c4be1b2f853fcc5d1bbfe3a59b3c0000000000000000
a69bc43a6de77bbdbc05d2be696f883fff211dbf7446943c0000000000000000
6f12833a3ee859bde483debe4f408b3f20631ebfe02d903c0000000000000000
6f12833a5af539bde7fbe9be6ff08d3fb29d1fbfb9fc873c0000000000000000
6f12033a091b1ebd7d3ff5bea54e903f4e6220bf24977f3c0000000000000000
6f12033adcd701bdc52000bfbe9f923fd3de20bf1ea7683c0000000000000000
6f12033a3d2cd4bc34a204bfe63f943f128320bf82e2473c0000000000000000
6f12033a77be9fbcde0209bf48bf953f4e6220bf3480373c0000000000000000
00000000fe6577bcff210dbfcb10973fb29d1fbf075f183c0000000000000000
0000000055c128bcd3de10bf2731983f1b9e1ebfd734ef3b0000000000000000
6f12033a89d2debbe63f14bff90f993ffb5c1dbf2e90a03b0000000000000000
00000000ed0d3ebbe71d17bf006f993f1ac01bbfed0d3e3b0000000000000000

