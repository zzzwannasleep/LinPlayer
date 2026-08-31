// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

/*

LICENSE:
  --- RAW ver.
  https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/v2.1.0/Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h

*/


//!HOOK MAIN
//!BIND HOOKED
//!DESC [AMD_FSR1_EASU] (SDK v1.1.4)
//!WIDTH OUTPUT.w
//!HEIGHT OUTPUT.h
//!WHEN OUTPUT.w HOOKED.w 1.0 * > OUTPUT.h HOOKED.h 1.0 * > *

#define FP16   1

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

FSR_FLOAT APrxLoRcpF1(FSR_FLOAT a) { return FSR_FLOAT(1.0) / max(a, FSR_FLOAT(1.0e-5)); }
FSR_FLOAT APrxLoRsqF1(FSR_FLOAT a) { return inversesqrt(max(a, FSR_FLOAT(1.0e-5))); }
FSR_FLOAT3 AMin3F3(FSR_FLOAT3 x, FSR_FLOAT3 y, FSR_FLOAT3 z) { return min(x, min(y, z)); }
FSR_FLOAT3 AMax3F3(FSR_FLOAT3 x, FSR_FLOAT3 y, FSR_FLOAT3 z) { return max(x, max(y, z)); }

void FsrEasuTapF(
	inout FSR_FLOAT3 aC,   // Accumulated color, with negative lobe.
	inout FSR_FLOAT aW,    // Accumulated weight.
	FSR_FLOAT2 off,        // Pixel offset from resolve position to tap.
	FSR_FLOAT2 dir,        // Gradient direction.
	FSR_FLOAT2 len,        // Length.
	FSR_FLOAT lob,         // Negative lobe strength.
	FSR_FLOAT clp,         // Clipping point.
	FSR_FLOAT3 c)          // Tap color.
{
	FSR_FLOAT2 v;
	v.x = (off.x * dir.x) + (off.y * dir.y);
	v.y = (off.x * (-dir.y)) + (off.y * dir.x);
	v *= len;
	FSR_FLOAT d2 = v.x * v.x + v.y * v.y;
	d2 = min(d2, clp);

	//  (25/16 * (2/5 * x^2 - 1)^2 - (25/16 - 1)) * (1/4 * x^2 - 1)^2
	//  |_______________________________________|   |_______________|
	//                   base                             window
	FSR_FLOAT wB = FSR_FLOAT(2.0 / 5.0) * d2 - FSR_FLOAT(1.0);
	FSR_FLOAT wA = lob * d2 - FSR_FLOAT(1.0);
	wB *= wB;
	wA *= wA;
	wB = FSR_FLOAT(25.0 / 16.0) * wB - FSR_FLOAT((25.0 / 16.0) - 1.0);
	FSR_FLOAT w = wB * wA;

	aC += c * w;
	aW += w;
}

void FsrEasuSetF(
	inout FSR_FLOAT2 dir,
	inout FSR_FLOAT len,
	FSR_FLOAT2 pp,
	bool biS, bool biT, bool biU, bool biV,
	FSR_FLOAT lA, FSR_FLOAT lB, FSR_FLOAT lC, FSR_FLOAT lD, FSR_FLOAT lE)
{
	//  s t
	//  u v
	FSR_FLOAT w = FSR_FLOAT(0.0);
	if (biS) w = (FSR_FLOAT(1.0) - pp.x) * (FSR_FLOAT(1.0) - pp.y);
	if (biT) w = pp.x * (FSR_FLOAT(1.0) - pp.y);
	if (biU) w = (FSR_FLOAT(1.0) - pp.x) * pp.y;
	if (biV) w = pp.x * pp.y;

	//    a
	//  b c d
	//    e
	FSR_FLOAT dc = lD - lC;
	FSR_FLOAT cb = lC - lB;
	FSR_FLOAT lenX = max(abs(dc), abs(cb));
	lenX = APrxLoRcpF1(lenX);
	FSR_FLOAT dirX = lD - lB;
	dir.x += dirX * w;
	lenX = clamp(abs(dirX) * lenX, FSR_FLOAT(0.0), FSR_FLOAT(1.0));
	lenX *= lenX;
	len += lenX * w;

	FSR_FLOAT ec = lE - lC;
	FSR_FLOAT ca = lC - lA;
	FSR_FLOAT lenY = max(abs(ec), abs(ca));
	lenY = APrxLoRcpF1(lenY);
	FSR_FLOAT dirY = lE - lA;
	dir.y += dirY * w;
	lenY = clamp(abs(dirY) * lenY, FSR_FLOAT(0.0), FSR_FLOAT(1.0));
	lenY *= lenY;
	len += lenY * w;
}

vec4 hook() {

	FSR_FLOAT2 pp = HOOKED_pos * HOOKED_size - FSR_FLOAT2(0.5);
	FSR_FLOAT2 fp = floor(pp);
	pp -= fp;

	// 12-tap kernel.
	//    b c
	//  e f g h
	//  i j k l
	//    n o
	// Gather 4 ordering.
	//  a b
	//  r g
	// For packed FP16
	//    a b    <- unused (z)
	//    r g
	//  a b a b
	//  r g r g
	//    a b
	//    r g    <- unused (z)

#if (defined(HOOKED_gather) && (__VERSION__ >= 400 || (GL_ES && __VERSION__ >= 310)))
	// Use textureGather for OpenGL 4.0+ / ES 3.1+
	FSR_FLOAT4 bczzR = HOOKED_gather(vec2((fp + vec2(1.0, -1.0)) * HOOKED_pt), 0);
	FSR_FLOAT4 bczzG = HOOKED_gather(vec2((fp + vec2(1.0, -1.0)) * HOOKED_pt), 1);
	FSR_FLOAT4 bczzB = HOOKED_gather(vec2((fp + vec2(1.0, -1.0)) * HOOKED_pt), 2);

	FSR_FLOAT4 ijfeR = HOOKED_gather(vec2((fp + vec2(0.0, 1.0)) * HOOKED_pt), 0);
	FSR_FLOAT4 ijfeG = HOOKED_gather(vec2((fp + vec2(0.0, 1.0)) * HOOKED_pt), 1);
	FSR_FLOAT4 ijfeB = HOOKED_gather(vec2((fp + vec2(0.0, 1.0)) * HOOKED_pt), 2);

	FSR_FLOAT4 klhgR = HOOKED_gather(vec2((fp + vec2(2.0, 1.0)) * HOOKED_pt), 0);
	FSR_FLOAT4 klhgG = HOOKED_gather(vec2((fp + vec2(2.0, 1.0)) * HOOKED_pt), 1);
	FSR_FLOAT4 klhgB = HOOKED_gather(vec2((fp + vec2(2.0, 1.0)) * HOOKED_pt), 2);

	FSR_FLOAT4 zzonR = HOOKED_gather(vec2((fp + vec2(1.0, 3.0)) * HOOKED_pt), 0);
	FSR_FLOAT4 zzonG = HOOKED_gather(vec2((fp + vec2(1.0, 3.0)) * HOOKED_pt), 1);
	FSR_FLOAT4 zzonB = HOOKED_gather(vec2((fp + vec2(1.0, 3.0)) * HOOKED_pt), 2);
#else
	// Fallback for pre-OpenGL 4.0 compatibility
	FSR_FLOAT3 b = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(0.5, -0.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 c = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(1.5, -0.5)) * HOOKED_pt)).rgb);

	FSR_FLOAT3 e = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(-0.5, 0.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 f = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 0.5, 0.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 g = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 1.5, 0.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 h = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 2.5, 0.5)) * HOOKED_pt)).rgb);

	FSR_FLOAT3 i = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(-0.5, 1.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 j = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 0.5, 1.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 k = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 1.5, 1.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 l = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2( 2.5, 1.5)) * HOOKED_pt)).rgb);

	FSR_FLOAT3 n = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(0.5, 2.5)) * HOOKED_pt)).rgb);
	FSR_FLOAT3 o = FSR_FLOAT3(HOOKED_tex(vec2((fp + vec2(1.5, 2.5)) * HOOKED_pt)).rgb);

	FSR_FLOAT4 bczzR = FSR_FLOAT4(b.r, c.r, 0.0, 0.0);
	FSR_FLOAT4 bczzG = FSR_FLOAT4(b.g, c.g, 0.0, 0.0);
	FSR_FLOAT4 bczzB = FSR_FLOAT4(b.b, c.b, 0.0, 0.0);

	FSR_FLOAT4 ijfeR = FSR_FLOAT4(i.r, j.r, f.r, e.r);
	FSR_FLOAT4 ijfeG = FSR_FLOAT4(i.g, j.g, f.g, e.g);
	FSR_FLOAT4 ijfeB = FSR_FLOAT4(i.b, j.b, f.b, e.b);

	FSR_FLOAT4 klhgR = FSR_FLOAT4(k.r, l.r, h.r, g.r);
	FSR_FLOAT4 klhgG = FSR_FLOAT4(k.g, l.g, h.g, g.g);
	FSR_FLOAT4 klhgB = FSR_FLOAT4(k.b, l.b, h.b, g.b);

	FSR_FLOAT4 zzonR = FSR_FLOAT4(0.0, 0.0, o.r, n.r);
	FSR_FLOAT4 zzonG = FSR_FLOAT4(0.0, 0.0, o.g, n.g);
	FSR_FLOAT4 zzonB = FSR_FLOAT4(0.0, 0.0, o.b, n.b);
#endif

	FSR_FLOAT4 bczzL = bczzB * FSR_FLOAT4(0.5) + (bczzR * FSR_FLOAT4(0.5) + bczzG);
	FSR_FLOAT4 ijfeL = ijfeB * FSR_FLOAT4(0.5) + (ijfeR * FSR_FLOAT4(0.5) + ijfeG);
	FSR_FLOAT4 klhgL = klhgB * FSR_FLOAT4(0.5) + (klhgR * FSR_FLOAT4(0.5) + klhgG);
	FSR_FLOAT4 zzonL = zzonB * FSR_FLOAT4(0.5) + (zzonR * FSR_FLOAT4(0.5) + zzonG);

	FSR_FLOAT bL = bczzL.x;
	FSR_FLOAT cL = bczzL.y;
	FSR_FLOAT iL = ijfeL.x;
	FSR_FLOAT jL = ijfeL.y;
	FSR_FLOAT fL = ijfeL.z;
	FSR_FLOAT eL = ijfeL.w;
	FSR_FLOAT kL = klhgL.x;
	FSR_FLOAT lL = klhgL.y;
	FSR_FLOAT hL = klhgL.z;
	FSR_FLOAT gL = klhgL.w;
	FSR_FLOAT oL = zzonL.z;
	FSR_FLOAT nL = zzonL.w;

	FSR_FLOAT2 dir = FSR_FLOAT2(0.0);
	FSR_FLOAT len = FSR_FLOAT(0.0);

	const bool deea = (target_size.x * target_size.y > HOOKED_size.x * HOOKED_size.y * 6.25);
	if (!deea) {
		FsrEasuSetF(dir, len, pp, true, false, false, false, bL, eL, fL, gL, jL);
		FsrEasuSetF(dir, len, pp, false, true, false, false, cL, fL, gL, hL, kL);
		FsrEasuSetF(dir, len, pp, false, false, true, false, fL, iL, jL, kL, nL);
		FsrEasuSetF(dir, len, pp, false, false, false, true, gL, jL, kL, lL, oL);
	}

	FSR_FLOAT2 dir2 = dir * dir;
	FSR_FLOAT dirR = dir2.x + dir2.y;
	bool zro = dirR < FSR_FLOAT(1.0 / 32768.0);
	dirR = APrxLoRsqF1(dirR);
	dirR = zro ? FSR_FLOAT(1.0) : dirR;
	dir.x = zro ? FSR_FLOAT(1.0) : dir.x;
	dir *= FSR_FLOAT2(dirR);

	len = len * FSR_FLOAT(0.5);
	len *= len;
	FSR_FLOAT stretch = (dir.x * dir.x + dir.y * dir.y) * APrxLoRcpF1(max(abs(dir.x), abs(dir.y)));
	FSR_FLOAT2 len2 = FSR_FLOAT2(FSR_FLOAT(1.0) + (stretch - FSR_FLOAT(1.0)) * len, FSR_FLOAT(1.0) + FSR_FLOAT(-0.5) * len);
	FSR_FLOAT lob = FSR_FLOAT(0.5) + FSR_FLOAT((1.0 / 4.0 - 0.04) - 0.5) * len;
	FSR_FLOAT clp = APrxLoRcpF1(lob);

	//    b c
	//  e f g h
	//  i j k l
	//    n o
	FSR_FLOAT3 min4 = min(AMin3F3(FSR_FLOAT3(ijfeR.z, ijfeG.z, ijfeB.z), FSR_FLOAT3(klhgR.w, klhgG.w, klhgB.w), FSR_FLOAT3(ijfeR.y, ijfeG.y, ijfeB.y)), FSR_FLOAT3(klhgR.x, klhgG.x, klhgB.x));
	FSR_FLOAT3 max4 = max(AMax3F3(FSR_FLOAT3(ijfeR.z, ijfeG.z, ijfeB.z), FSR_FLOAT3(klhgR.w, klhgG.w, klhgB.w), FSR_FLOAT3(ijfeR.y, ijfeG.y, ijfeB.y)), FSR_FLOAT3(klhgR.x, klhgG.x, klhgB.x));

	FSR_FLOAT3 aC = FSR_FLOAT3(0.0);
	FSR_FLOAT aW = FSR_FLOAT(0.0);
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 0.0,-1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(bczzR.x, bczzG.x, bczzB.x)); // b
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 1.0,-1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(bczzR.y, bczzG.y, bczzB.y)); // c
	FsrEasuTapF(aC, aW, FSR_FLOAT2(-1.0, 1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 0.0, 1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(ijfeR.y, ijfeG.y, ijfeB.y)); // j
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 0.0, 0.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(ijfeR.z, ijfeG.z, ijfeB.z)); // f
	FsrEasuTapF(aC, aW, FSR_FLOAT2(-1.0, 0.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 1.0, 1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(klhgR.x, klhgG.x, klhgB.x)); // k
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 2.0, 1.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(klhgR.y, klhgG.y, klhgB.y)); // l
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 2.0, 0.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(klhgR.z, klhgG.z, klhgB.z)); // h
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 1.0, 0.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(klhgR.w, klhgG.w, klhgB.w)); // g
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 1.0, 2.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(zzonR.z, zzonG.z, zzonB.z)); // o
	FsrEasuTapF(aC, aW, FSR_FLOAT2( 0.0, 2.0) - pp, dir, len2, lob, clp, FSR_FLOAT3(zzonR.w, zzonG.w, zzonB.w)); // n

	FSR_FLOAT3 pix = min(max4, max(min4, aC / aW));
	float alpha = HOOKED_tex(HOOKED_pos).a;
	return vec4(pix, alpha);

}

