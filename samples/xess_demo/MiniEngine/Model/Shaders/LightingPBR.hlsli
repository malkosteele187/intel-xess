//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):	James Stanard
//				Alex Nankervis
//
// Thanks to Michal Drobot for his feedback.

#include "Common.hlsli"
#include "LightGrid.hlsli"
#include "BRDF.hlsli"

cbuffer GlobalConstants : register(b1)
{
    float4x4 ViewProjMatrix;
    float4x4 SunShadowMatrix;
    float3x3 EnvRotation;
    float3 ViewerPos;
    float3 SunDirection;
    float3 SunIntensity;
    float4 ShadowTexelSize;
    float4 InvTileDim;
    uint4 TileCount;
    uint4 FirstLightIndex;
    float IBLRange;
    float IBLBias;
    float ViewMipBias; // MipBias value for sampling.
    float DebugFlag;
}


StructuredBuffer<LightData> lightBuffer     : register(t15);
Texture2DArray<float> lightShadowArrayTex   : register(t16);

ByteAddressBuffer lightGrid                         : register(t17);
ByteAddressBuffer lightGridBitMask                  : register(t18);
ByteAddressBuffer lightGridTransparent              : register(t19);
ByteAddressBuffer lightGridBitMaskTransparent       : register(t20);

#define SHADOW_PCF_13

float GetDirectionalShadow( float3 ShadowCoord, Texture2D<float> texShadow )
{
    float result = 0;
#ifdef SINGLE_SAMPLE
    result = texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy, ShadowCoord.z );
#elif defined(SHADOW_PCF_5)
    float d = ShadowTexelSize.x;
    result = (
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy, ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, -d), ShadowCoord.z)
        ) / 5.0;

#elif defined(SHADOW_PCF_13)
    float d = ShadowTexelSize.x;
    result = (
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy, ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, -d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d, d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d, d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d, -d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d, -d), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d * 2.0, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d * 2.0, 0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, d * 2.0), ShadowCoord.z) +
        texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(0, -d * 2.0), ShadowCoord.z)
        ) / 13.0;
#else
    const float Dilation = 2.0;
    float d1 = Dilation * ShadowTexelSize.x * 0.125;
    float d2 = Dilation * ShadowTexelSize.x * 0.875;
    float d3 = Dilation * ShadowTexelSize.x * 0.625;
    float d4 = Dilation * ShadowTexelSize.x * 0.375;
    float result = (
        2.0 * texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy, ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d2,  d1), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d1, -d2), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d2, -d1), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d1,  d2), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d4,  d3), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2(-d3, -d4), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d4, -d3), ShadowCoord.z ) +
        texShadow.SampleCmpLevelZero( shadowSampler, ShadowCoord.xy + float2( d3,  d4), ShadowCoord.z )
        ) / 10.0;
#endif

    return result * result;
}

float GetShadowConeLight(uint lightIndex, float3 shadowCoord)
{
#if defined(SINGLE_SAMPLE)
    float result = lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z);
#elif defined(SHADOW_PCF_5)
    float texelSize = 1.0 / 512.0;
    float result = (
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(texelSize, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-texelSize, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, -texelSize), lightIndex), shadowCoord.z)
        ) / 5.0;
#elif defined(SHADOW_PCF_13)
    float texelSize = 1.0 / 512.0;
    float result = (
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(texelSize, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-texelSize, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, -texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(texelSize, texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-texelSize, texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(texelSize, -texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-texelSize, -texelSize), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(texelSize * 2.0, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-texelSize * 2.0, 0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, texelSize * 2.0), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(0, -texelSize * 2.0), lightIndex), shadowCoord.z)
        ) / 13.0;
#else
    float texelSize = 1.0 / 512.0;
    const float Dilation = 2.0;
    float d1 = Dilation * texelSize * 0.125;
    float d2 = Dilation * texelSize * 0.875;
    float d3 = Dilation * texelSize * 0.625;
    float d4 = Dilation * texelSize * 0.375;

    float result = (
        2.0 * lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-d2,  d1), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-d1, -d2), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2( d2, -d1), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2( d1,  d2), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-d4,  d3), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2(-d3, -d4), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2( d4, -d3), lightIndex), shadowCoord.z) +
        lightShadowArrayTex.SampleCmpLevelZero(shadowSampler, float3(shadowCoord.xy + float2( d3,  d4), lightIndex), shadowCoord.z)
        ) / 10.0;
#endif

    return result * result;
}

float3 ApplyLightCommon(SurfaceProperties surface, float3 lightDir, float3 lightColor)
{
    LightProperties Light;
    Light.L = lightDir;

    // Half vector
    float3 H = normalize(lightDir + surface.V);

    // Pre-compute dot products
    Light.NdotL = clamp(dot(surface.N, lightDir), 1e-6, 1.0);
    Light.LdotH = clamp(dot(lightDir, H), 1e-6, 1.0);
    Light.NdotH = clamp(dot(surface.N, H), 1e-6, 1.0);

    // Diffuse & specular factors
    float3 diffuse = Diffuse_Lambertian(surface);
    float3 specular = Specular_BRDF(surface, Light);

    return Light.NdotL * lightColor * (diffuse + specular);
}

float3 ApplyDirectionalLight(SurfaceProperties surface, 
    float3  lightDir, 
    float3  lightColor,
    float3	shadowCoord,	// Shadow coordinate (Shadow map UV & light-relative Z)
    Texture2D<float> ShadowMap
    )
{
    float shadow = GetDirectionalShadow(shadowCoord, ShadowMap);

    return shadow * ApplyLightCommon(
        surface,
        lightDir,
        lightColor
        );
}

float3 ApplyPointLight(SurfaceProperties surface, 
    float3	worldPos,		// World-space fragment position
    float3	lightPos,		// World-space light position
    float	lightRadiusSq,
    float3	lightColor		// Radiance of directional light
    )
{
    float3 lightDir = lightPos - worldPos;
    float lightDistSq = dot(lightDir, lightDir);
    float invLightDist = rsqrt(lightDistSq);
    lightDir *= invLightDist;

    // modify 1/d^2 * R^2 to fall off at a fixed radius
    // (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
    float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
    distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

    return distanceFalloff * ApplyLightCommon(
        surface,
        lightDir,
        lightColor
        );
}

float3 ApplyConeLight(SurfaceProperties surface, 
    float3	worldPos,		// World-space fragment position
    float3	lightPos,		// World-space light position
    float	lightRadiusSq,
    float3	lightColor,		// Radiance of directional light
    float3	coneDir,
    float2	coneAngles
    )
{
    float3 lightDir = lightPos - worldPos;
    float lightDistSq = dot(lightDir, lightDir);
    float invLightDist = rsqrt(lightDistSq);
    lightDir *= invLightDist;

    // modify 1/d^2 * R^2 to fall off at a fixed radius
    // (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
    float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
    distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

    float coneFalloff = dot(-lightDir, coneDir);
    coneFalloff = saturate((coneFalloff - coneAngles.y) * coneAngles.x);

    return (coneFalloff * distanceFalloff) * ApplyLightCommon(
        surface,
        lightDir,
        lightColor
        );
}

float3 ApplyConeShadowedLight(SurfaceProperties surface, 
    float3	worldPos,		// World-space fragment position
    float3	lightPos,		// World-space light position
    float	lightRadiusSq,
    float3	lightColor,		// Radiance of directional light
    float3	coneDir,
    float2	coneAngles,
    float4x4 shadowTextureMatrix,
    uint	lightIndex
    )
{
    float4 shadowCoord = mul(shadowTextureMatrix, float4(worldPos, 1.0));
    shadowCoord.xyz *= rcp(shadowCoord.w);
    float shadow = GetShadowConeLight(lightIndex, shadowCoord.xyz);

    return shadow * ApplyConeLight(surface,
        worldPos,
        lightPos,
        lightRadiusSq,
        lightColor,
        coneDir,
        coneAngles
        );
}

// options for F+ variants and optimizations
#if 0 // SM6.0
#define _WAVE_OP
#endif

// options for F+ variants and optimizations
#ifdef _WAVE_OP // SM 6.0 (new shader compiler)

// choose one of these:
//# define BIT_MASK
# define BIT_MASK_SORTED
//# define SCALAR_LOOP
//# define SCALAR_BRANCH

// enable to amortize latency of vector read in exchange for additional VGPRs being held
# define LIGHT_GRID_PRELOADING

// configured for 32 sphere lights, 64 cone lights, and 32 cone shadowed lights
# define POINT_LIGHT_GROUPS			1
# define SPOT_LIGHT_GROUPS			2
# define SHADOWED_SPOT_LIGHT_GROUPS	1
# define POINT_LIGHT_GROUPS_TAIL			POINT_LIGHT_GROUPS
# define SPOT_LIGHT_GROUPS_TAIL				POINT_LIGHT_GROUPS_TAIL + SPOT_LIGHT_GROUPS
# define SHADOWED_SPOT_LIGHT_GROUPS_TAIL	SPOT_LIGHT_GROUPS_TAIL + SHADOWED_SPOT_LIGHT_GROUPS

uint GetGroupBits(uint groupIndex, uint tileIndex, uint lightBitMaskGroups[4])
{
#ifdef LIGHT_GRID_PRELOADING
    return lightBitMaskGroups[groupIndex];
#else
    return lightGridBitMask.Load(tileIndex * 16 + groupIndex * 4);
#endif
}

uint WaveOr(uint mask)
{
    return WaveActiveBitOr(mask);
}

uint64_t Ballot64(bool b)
{
    uint4 ballots = WaveActiveBallot(b);
    return (uint64_t)ballots.y << 32 | (uint64_t)ballots.x;
}

#endif // _WAVE_OP

// Helper function for iterating over a sparse list of bits.  Gets the offset of the next
// set bit, clears it, and returns the offset.
uint PullNextBit( inout uint bits )
{
    uint bitIndex = firstbitlow(bits);
    bits ^= 1 << bitIndex;
    return bitIndex;
}

float3 ApplyAmbientLight(
    float3	diffuse,	// Diffuse albedo
    float	ao,			// Pre-computed ambient-occlusion
    float3	lightColor	// Radiance of ambient light
    )
{
    return ao * diffuse * lightColor;
}

void ShadeLightsTiled(inout float3 colorSum, 
    uint2 pixelPos,
    SurfaceProperties surface,
    float3 worldPos,
    ByteAddressBuffer lightGrid,
    ByteAddressBuffer lightGridBitMask
    )
{
    uint2 tilePos = GetTilePos(pixelPos, InvTileDim.xy);
    uint tileIndex = GetTileIndex(tilePos, TileCount.x);
    uint tileOffset = GetTileOffset(tileIndex);

    // Light Grid Preloading setup
    uint lightBitMaskGroups[4] = { 0, 0, 0, 0 };
#if defined(LIGHT_GRID_PRELOADING)
    uint4 lightBitMask = lightGridBitMask.Load4(tileIndex * 16);
    
    lightBitMaskGroups[0] = lightBitMask.x;
    lightBitMaskGroups[1] = lightBitMask.y;
    lightBitMaskGroups[2] = lightBitMask.z;
    lightBitMaskGroups[3] = lightBitMask.w;
#endif

#define POINT_LIGHT_ARGS \
    surface, \
    worldPos, \
    lightData.pos, \
    lightData.radiusSq, \
    lightData.color

#define CONE_LIGHT_ARGS \
    POINT_LIGHT_ARGS, \
    lightData.coneDir, \
    lightData.coneAngles

#define SHADOWED_LIGHT_ARGS \
    CONE_LIGHT_ARGS, \
    lightData.shadowTextureMatrix, \
    lightIndex

#if defined(BIT_MASK)
    uint64_t threadMask = Ballot64(tileIndex != ~0); // attempt to get starting exec mask

    for (uint groupIndex = 0; groupIndex < 4; groupIndex++)
    {
        // combine across threads
        uint groupBits = WaveOr(GetGroupBits(groupIndex, tileIndex, lightBitMaskGroups));

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            LightData lightData = lightBuffer[lightIndex];

            if (lightIndex < FirstLightIndex.x) // sphere
            {
                colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
            }
            else if (lightIndex < FirstLightIndex.y) // cone
            {
                colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
            }
            else // cone w/ shadow map
            {
                colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
            }
        }
    }

#elif defined(BIT_MASK_SORTED)

    // Get light type groups - these can be predefined as compile time constants to enable unrolling and better scheduling of vector reads
    uint pointLightGroupTail		= POINT_LIGHT_GROUPS_TAIL;
    uint spotLightGroupTail			= SPOT_LIGHT_GROUPS_TAIL;
    uint spotShadowLightGroupTail	= SHADOWED_SPOT_LIGHT_GROUPS_TAIL;

    uint groupBitsMasks[4] = { 0, 0, 0, 0 };
    for (int i = 0; i < 4; i++)
    {
        // combine across threads
        groupBitsMasks[i] = WaveOr(GetGroupBits(i, tileIndex, lightBitMaskGroups));
    }

    uint groupIndex;

    for (groupIndex = 0; groupIndex < pointLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // sphere
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }
    }

    for (groupIndex = pointLightGroupTail; groupIndex < spotLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // cone
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }
    }

    for (groupIndex = spotLightGroupTail; groupIndex < spotShadowLightGroupTail; groupIndex++)
    {
        uint groupBits = groupBitsMasks[groupIndex];

        while (groupBits != 0)
        {
            uint bitIndex = PullNextBit(groupBits);
            uint lightIndex = 32 * groupIndex + bitIndex;

            // cone w/ shadow map
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }

#elif defined(SCALAR_LOOP)
    uint64_t threadMask = Ballot64(tileOffset != ~0); // attempt to get starting exec mask
    uint64_t laneBit = 1ull << WaveGetLaneIndex();

    while ((threadMask & laneBit) != 0) // is this thread waiting to be processed?
    { // exec is now the set of remaining threads
        // grab the tile offset for the first active thread
        uint uniformTileOffset = WaveReadLaneFirst(tileOffset);
        // mask of which threads have the same tile offset as the first active thread
        uint64_t uniformMask = Ballot64(tileOffset == uniformTileOffset);

        if (any((uniformMask & laneBit) != 0)) // is this thread one of the current set of uniform threads?
        {
            uint tileLightCount = lightGrid.Load(uniformTileOffset + 0);
            uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
            uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
            uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

            uint tileLightLoadOffset = uniformTileOffset + 4;
            uint n;

            // sphere
            for (n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
            }

            // cone
            for (n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
            }

            // cone w/ shadow map
            for (n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
            {
                uint lightIndex = lightGrid.Load(tileLightLoadOffset);
                LightData lightData = lightBuffer[lightIndex];
                colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
            }
        }

        // strip the current set of uniform threads from the exec mask for the next loop iteration
        threadMask &= ~uniformMask;
    }

#elif defined(SCALAR_BRANCH)

    if (Ballot64(tileOffset == WaveReadLaneFirst(tileOffset)) == ~0ull)
    {
        // uniform branch
        tileOffset = WaveReadLaneFirst(tileOffset);

        uint tileLightCount = lightGrid.Load(tileOffset + 0);
        uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
        uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
        uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

        uint tileLightLoadOffset = tileOffset + 4;
        uint n;

        // sphere
        for (n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }

        // cone
        for (n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }

        // cone w/ shadow map
        for (n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }
    else
    {
        // divergent branch
        uint tileLightCount = lightGrid.Load(tileOffset + 0);
        uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
        uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
        uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

        uint tileLightLoadOffset = tileOffset + 4;
        uint n;

        // sphere
        for (n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
        }

        // cone
        for (n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
        }

        // cone w/ shadow map
        for (n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
        {
            uint lightIndex = lightGrid.Load(tileLightLoadOffset);
            LightData lightData = lightBuffer[lightIndex];
            colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
        }
    }

#else // SM 5.0 (no wave intrinsics)

    uint tileLightCount = lightGrid.Load(tileOffset + 0);
    uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
    uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
    uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

    uint tileLightLoadOffset = tileOffset + 4;

    // sphere
    uint n;
    for (n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
    }

    // cone
    for (n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
    }

    // cone w/ shadow map
    for (n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
    {
        uint lightIndex = lightGrid.Load(tileLightLoadOffset);
        LightData lightData = lightBuffer[lightIndex];
        colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
    }
#endif
}

static const uint ALPHA_BLEND = 7;

void ShadeLights(inout float3 colorSum,
    uint2 pixelPos,
    SurfaceProperties surface,
    float3 worldPos,
    uint flags)
{
    bool transparent = (flags >> ALPHA_BLEND) & 1;
    if (transparent)
    {
        ShadeLightsTiled(colorSum, pixelPos, surface, worldPos, lightGridTransparent, lightGridBitMaskTransparent);
    }
    else
    {
        ShadeLightsTiled(colorSum, pixelPos, surface, worldPos, lightGrid, lightGridBitMask);
    }
}