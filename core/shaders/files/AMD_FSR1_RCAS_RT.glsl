// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.1.0/Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h

*/


//!PARAM SHARP
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 4.0
0.2

//!PARAM NDS
//!TYPE DEFINE
//!MINIMUM 0
//!MAXIMUM 1
1


//!HOOK MAIN
//!BIND HOOKED
//!DESC [AMD_FSR1_RCAS_RT] (SDK v2.0.0)
//!WHEN SHARP 4.0 <

#define FP16             1
#define FSR_RCAS_LIMIT   (0.25 - (1.0 / 16.0))

#if FP16
	#ifdef GL_ES
		precision mediump float;
	#else
		precision highp float;
	#endif
	#define FSR_FLOAT float
	#define FSR_FLOAT2 vec2
	#define FSR_FLOAT3 vec3
	#define FSR_FLOAT4 vec4
#else
	precision highp float;
	#define FSR_FLOAT float
	#define FSR_FLOAT2 vec2
	#define FSR_FLOAT3 vec3
	#define FSR_FLOAT4 vec4
#endif

FSR_FLOAT APrxMedRcpF1_RCAS(FSR_FLOAT a) { return FSR_FLOAT(1.0) / a; }
FSR_FLOAT AMin3F1_RCAS(FSR_FLOAT x, FSR_FLOAT y, FSR_FLOAT z) { return min(x, min(y, z)); }
FSR_FLOAT AMax3F1_RCAS(FSR_FLOAT x, FSR_FLOAT y, FSR_FLOAT z) { return max(x, max(y, z)); }

vec4 hook() {

	//    b
	//  d e f
	//    h
	FSR_FLOAT3 b = FSR_FLOAT3(HOOKED_texOff(vec2( 0.0, -1.0)).rgb);
	FSR_FLOAT3 d = FSR_FLOAT3(HOOKED_texOff(vec2(-1.0,  0.0)).rgb);
	vec4 ee = HOOKED_tex(HOOKED_pos);
	FSR_FLOAT3 e = FSR_FLOAT3(ee.rgb);
	float alpha = ee.a;
	FSR_FLOAT3 f = FSR_FLOAT3(HOOKED_texOff(vec2( 1.0,  0.0)).rgb);
	FSR_FLOAT3 h = FSR_FLOAT3(HOOKED_texOff(vec2( 0.0,  1.0)).rgb);

	FSR_FLOAT bR = b.r, bG = b.g, bB = b.b;
	FSR_FLOAT dR = d.r, dG = d.g, dB = d.b;
	FSR_FLOAT eR = e.r, eG = e.g, eB = e.b;
	FSR_FLOAT fR = f.r, fG = f.g, fB = f.b;
	FSR_FLOAT hR = h.r, hG = h.g, hB = h.b;

	FSR_FLOAT bL = bB * FSR_FLOAT(0.5) + (bR * FSR_FLOAT(0.5) + bG);
	FSR_FLOAT dL = dB * FSR_FLOAT(0.5) + (dR * FSR_FLOAT(0.5) + dG);
	FSR_FLOAT eL = eB * FSR_FLOAT(0.5) + (eR * FSR_FLOAT(0.5) + eG);
	FSR_FLOAT fL = fB * FSR_FLOAT(0.5) + (fR * FSR_FLOAT(0.5) + fG);
	FSR_FLOAT hL = hB * FSR_FLOAT(0.5) + (hR * FSR_FLOAT(0.5) + hG);

	// Noise detection
	FSR_FLOAT nz = FSR_FLOAT(0.25) * bL + FSR_FLOAT(0.25) * dL + FSR_FLOAT(0.25) * fL + FSR_FLOAT(0.25) * hL - eL;
	FSR_FLOAT range = AMax3F1_RCAS(AMax3F1_RCAS(bL, dL, eL), fL, hL) - AMin3F1_RCAS(AMin3F1_RCAS(bL, dL, eL), fL, hL);
	nz = clamp(abs(nz) * APrxMedRcpF1_RCAS(range), FSR_FLOAT(0.0), FSR_FLOAT(1.0));
	nz = FSR_FLOAT(-0.5) * nz + FSR_FLOAT(1.0);

	// Min and max of ring
	FSR_FLOAT mn4R = min(AMin3F1_RCAS(bR, dR, fR), hR);
	FSR_FLOAT mn4G = min(AMin3F1_RCAS(bG, dG, fG), hG);
	FSR_FLOAT mn4B = min(AMin3F1_RCAS(bB, dB, fB), hB);
	FSR_FLOAT mx4R = max(AMax3F1_RCAS(bR, dR, fR), hR);
	FSR_FLOAT mx4G = max(AMax3F1_RCAS(bG, dG, fG), hG);
	FSR_FLOAT mx4B = max(AMax3F1_RCAS(bB, dB, fB), hB);

	FSR_FLOAT2 peakC = FSR_FLOAT2(1.0, -4.0);

	// Limiters
	FSR_FLOAT minL = min(AMin3F1_RCAS(bL, dL, fL), hL);
	FSR_FLOAT lowerLimiterMultiplier = clamp(eL / minL, FSR_FLOAT(0.0), FSR_FLOAT(1.0));

	FSR_FLOAT hitMinR = mn4R / (FSR_FLOAT(4.0) * mx4R) * lowerLimiterMultiplier;
	FSR_FLOAT hitMinG = mn4G / (FSR_FLOAT(4.0) * mx4G) * lowerLimiterMultiplier;
	FSR_FLOAT hitMinB = mn4B / (FSR_FLOAT(4.0) * mx4B) * lowerLimiterMultiplier;
	FSR_FLOAT hitMaxR = (peakC.x - mx4R) / (FSR_FLOAT(4.0) * mn4R + peakC.y);
	FSR_FLOAT hitMaxG = (peakC.x - mx4G) / (FSR_FLOAT(4.0) * mn4G + peakC.y);
	FSR_FLOAT hitMaxB = (peakC.x - mx4B) / (FSR_FLOAT(4.0) * mn4B + peakC.y);

	FSR_FLOAT lobeR = max(-hitMinR, hitMaxR);
	FSR_FLOAT lobeG = max(-hitMinG, hitMaxG);
	FSR_FLOAT lobeB = max(-hitMinB, hitMaxB);

	// Apply sharpness
	FSR_FLOAT sharp = exp2(-SHARP);
	FSR_FLOAT lobe = max(FSR_FLOAT(-FSR_RCAS_LIMIT), min(AMax3F1_RCAS(lobeR, lobeG, lobeB), FSR_FLOAT(0.0))) * sharp;

#if NDS
	lobe *= nz;
#endif

	FSR_FLOAT rcpL = APrxMedRcpF1_RCAS(FSR_FLOAT(4.0) * lobe + FSR_FLOAT(1.0));
	FSR_FLOAT pixR = (lobe * bR + lobe * dR + lobe * hR + lobe * fR + eR) * rcpL;
	FSR_FLOAT pixG = (lobe * bG + lobe * dG + lobe * hG + lobe * fG + eG) * rcpL;
	FSR_FLOAT pixB = (lobe * bB + lobe * dB + lobe * hB + lobe * fB + eB) * rcpL;
	return vec4(pixR, pixG, pixB, alpha);

}

