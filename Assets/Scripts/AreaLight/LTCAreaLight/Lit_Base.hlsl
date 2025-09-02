#ifndef UNIVERSAL_LIT_BASE_INCLUDED
#define UNIVERSAL_LIT_BASE_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Debug/Debugging3D.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/GlobalIllumination.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RealtimeLights.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/AmbientOcclusion.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DBuffer.hlsl"
#include "../PreIntegratedFGD/PreIntegratedFGD.hlsl"
#include "AreaLighting.hlsl"
#include "LTCAreaLight.hlsl"

#define MAX_AREA_LIGHTS 10
#define GPULIGHTTYPE_TUBE (5)
#define GPULIGHTTYPE_RECTANGLE (6)

struct DirectLighting
{
    real3 diffuse;
    real3 specular;
};

struct AreaLightData
{
    int lightType;
    float intensity;
    float range;
    // float diffuseDimmer;
    // float specularDimmer;
    float rangeAttenuationScale;
    float rangeAttenuationBias;
    float2 size;
    float3 color;
    float3 positionRWS;
    float3 up;
    float3 right;
    float3 forward;
};

CBUFFER_START(AreaLightBuffer)
    int _AreaLightCount;
    int _AreaLightTypeArray[MAX_AREA_LIGHTS];
    //x:range y:rangeAttenuationScale z:rangeAttenuationBias, w:intensity
    float4 _AreaLightRangeAndIntensityArray[MAX_AREA_LIGHTS];
    float2 _AreaLightSizeArray[MAX_AREA_LIGHTS];
    float3 _AreaLightColorArray[MAX_AREA_LIGHTS];
    float3 _AreaLightPositionArray[MAX_AREA_LIGHTS];
    float3 _AreaLightDirectionUpArray[MAX_AREA_LIGHTS];
    float3 _AreaLightDirectionRightArray[MAX_AREA_LIGHTS];
    float3 _AreaLightDirectionForwardArray[MAX_AREA_LIGHTS];
CBUFFER_END

// Precomputed lighting data to send to the various lighting functions
struct PreLightData
{
    float NdotV;                     // Could be negative due to normal mapping, use ClampNdotV()

    // // GGX
    // float partLambdaV;
    float energyCompensation;

    float3 specularFGD;              // Store preintegrated BSDF for both specular and diffuse
    float  diffuseFGD;

    // Area lights (17 VGPRs)
    // TODO: 'orthoBasisViewNormal' is just a rotation around the normal and should thus be just 1x VGPR.
    float3x3 orthoBasisViewNormal;   // Right-handed view-dependent orthogonal basis around the normal (6x VGPRs)
    float3x3 ltcTransformDiffuse;    // Inverse transformation for Lambertian or Disney Diffuse        (4x VGPRs)
    float3x3 ltcTransformSpecular;   // Inverse transformation for GGX                                 (4x VGPRs)

    
};

struct BSDFData
{
    float3 normalWS;
    real3 fresnel0;
    real perceptualRoughness;
};

// Expects non-normalized vertex positions.
// Same as regular PolygonIrradiance found in AreaLighting.hlsl except I need the form factor F
// (cf. http://blog.selfshadow.com/publications/s2016-advances/s2016_ltc_rnd.pdf pp. 92 for an explanation on the meaning of that sphere approximation)
real PolygonIrradiance(real4x3 L, out float3 F)
{
    UNITY_UNROLL
        for (uint i = 0; i < 4; i++)
        {
            L[i] = normalize(L[i]);
        }

    F = 0.0;

    UNITY_UNROLL
        for (uint edge = 0; edge < 4; edge++)
        {
            real3 V1 = L[edge];
            real3 V2 = L[(edge + 1) % 4];

            F += INV_TWO_PI * ComputeEdgeFactor(V1, V2);
        }

    // Clamp invalid values to avoid visual artifacts.
    real f2 = saturate(dot(F, F));
    real sinSqSigma = min(sqrt(f2), 0.999);
    real cosOmega = clamp(F.z * rsqrt(f2), -1, 1);

    return DiffuseSphereLightIrradiance(sinSqSigma, cosOmega);
}

PreLightData GetPreLightData(float3 positionWS, BSDFData bsdfData)
{
    half3 V = GetWorldSpaceNormalizeViewDir(positionWS);
    PreLightData preLightData;
    ZERO_INITIALIZE(PreLightData, preLightData);

    float3 N = bsdfData.normalWS;
    preLightData.NdotV = dot(N, V);
    float perceptualRoughness = bsdfData.perceptualRoughness;

    float clampedNdotV = ClampNdotV(preLightData.NdotV);

    // Handle IBL + area light + multiscattering.
    // Note: use the not modified by anisotropy iblPerceptualRoughness here.
    float specularReflectivity;
    GetPreIntegratedFGDGGXAndDisneyDiffuse(clampedNdotV, perceptualRoughness, bsdfData.fresnel0, preLightData.specularFGD, preLightData.diffuseFGD, specularReflectivity);
#ifdef USE_DIFFUSE_LAMBERT_BRDF
    preLightData.diffuseFGD = 1.0;
#endif

    //屏蔽GGX高光能量补偿
// #ifdef LIT_USE_GGX_ENERGY_COMPENSATION
//     // Ref: Practical multiple scattering compensation for microfacet models.
//     // We only apply the formulation for metals.
//     // For dielectrics, the change of reflectance is negligible.
//     // We deem the intensity difference of a couple of percent for high values of roughness
//     // to not be worth the cost of another precomputed table.
//     // Note: this formulation bakes the BSDF non-symmetric!
     preLightData.energyCompensation = 1.0 / specularReflectivity - 1.0;
// #else
//     preLightData.energyCompensation = 0.0;
// #endif // LIT_USE_GGX_ENERGY_COMPENSATION



    // Area light
    // UVs for sampling the LUTs
    // We use V = sqrt( 1 - cos(theta) ) for parametrization which is kind of linear and only requires a single sqrt() instead of an expensive acos()
    float cosThetaParam = sqrt(1 - clampedNdotV); // For Area light - UVs for sampling the LUTs
    float2 uv = Remap01ToHalfTexelCoord(float2(bsdfData.perceptualRoughness, cosThetaParam), LTC_LUT_SIZE);

    // Note we load the matrix transpose (avoid to have to transpose it in shader)
#ifdef USE_DIFFUSE_LAMBERT_BRDF
    preLightData.ltcTransformDiffuse = k_identity3x3;
#else
    // Get the inverse LTC matrix for Disney Diffuse
    preLightData.ltcTransformDiffuse      = 0.0;
    preLightData.ltcTransformDiffuse._m22 = 1.0;
    preLightData.ltcTransformDiffuse._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTCLIGHTINGMODEL_DISNEY_DIFFUSE, 0);
#endif

    // Get the inverse LTC matrix for GGX
    // Note we load the matrix transpose (avoid to have to transpose it in shader)
    preLightData.ltcTransformSpecular      = 0.0;
    preLightData.ltcTransformSpecular._m22 = 1.0;
    preLightData.ltcTransformSpecular._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTCLIGHTINGMODEL_GGX, 0);

    // Construct a right-handed view-dependent orthogonal basis around the normal
    preLightData.orthoBasisViewNormal = GetOrthoBasisViewNormal(V, N, preLightData.NdotV);

    //GGX高光补偿
    preLightData.energyCompensation *=  bsdfData.fresnel0;
    return preLightData;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Line - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

half3 EvaluateBSDF_Line(InputData inputData, PreLightData preLightData, AreaLightData lightData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = inputData.positionWS;

    float  len = lightData.size.x;
    float3 T   = lightData.right;

    float3 unL = lightData.positionRWS - positionWS;

    // Pick the major axis of the ellipsoid.
    float3 axis = lightData.right;

    // We define the ellipsoid s.t. r1 = (r + len / 2), r2 = r3 = r.
    // TODO: This could be precomputed.
    float range          = lightData.range;
    float invAspectRatio = saturate(range / (range + (0.5 * len)));

    // Compute the light attenuation.
    float intensity = EllipsoidalDistanceAttenuation(unL, axis, invAspectRatio,
                                                     lightData.rangeAttenuationScale,
                                                     lightData.rangeAttenuationBias);

    intensity *= lightData.intensity;
    // Terminate if the shaded point is too far away.
    if (intensity != 0.0)
    {

        // Translate the light s.t. the shaded point is at the origin of the coordinate system.
        lightData.positionRWS -= positionWS;

        // TODO: some of this could be precomputed.
        float3 P1 = lightData.positionRWS - T * (0.5 * len);
        float3 P2 = lightData.positionRWS + T * (0.5 * len);

        // Rotate the endpoints into the local coordinate system.
        P1 = mul(P1, transpose(preLightData.orthoBasisViewNormal));
        P2 = mul(P2, transpose(preLightData.orthoBasisViewNormal));

        // Compute the binormal in the local coordinate system.
        float3 B = normalize(cross(P1, P2));

        float ltcValue;

        // Evaluate the diffuse part
        ltcValue = LTCEvaluate(P1, P2, B, preLightData.ltcTransformDiffuse);
        // ltcValue *= lightData.diffuseDimmer;
        ltcValue *= intensity;
        // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().

        // See comment for specular magnitude, it apply to diffuse as well
        lighting.diffuse = preLightData.diffuseFGD * ltcValue;

        // Evaluate the specular part
        ltcValue = LTCEvaluate(P1, P2, B, preLightData.ltcTransformSpecular);
        // ltcValue *= lightData.specularDimmer;
        ltcValue *= intensity;
        // We need to multiply by the magnitude of the integral of the BRDF
        // ref: http://advances.realtimerendering.com/s2016/s2016_ltc_fresnel.pdf
        // This value is what we store in specularFGD, so reuse it
        lighting.specular = preLightData.specularFGD * ltcValue;

        // Save ALU by applying 'lightData.color' only once.
        lighting.diffuse *= lightData.color;
        lighting.specular *= lightData.color;

    #ifdef DEBUG_DISPLAY
        if (_DebugLightingMode == DEBUGLIGHTINGMODE_LUX_METER)
        {
            // Only lighting, not BSDF
            // Apply area light on lambert then multiply by PI to cancel Lambert
            lighting.diffuse = LTCEvaluate(P1, P2, B, k_identity3x3);
            // lighting.diffuse *= PI * lightData.diffuseDimmer;
            lighting.diffuse *= PI * intensity;
        }
    #endif
    }
    return lighting.diffuse + lighting.specular * (1.0f + preLightData.energyCompensation);
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Rect - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

// #define ELLIPSOIDAL_ATTENUATION

half3 EvaluateBSDF_Rect(InputData inputData, PreLightData preLightData, AreaLightData lightData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = inputData.positionWS;

    float3 unL = lightData.positionRWS - positionWS;

    if (dot(lightData.forward, unL) < FLT_EPS)
    {
        // Rotate the light direction into the light space.
        float3x3 lightToWorld = float3x3(lightData.right, lightData.up, -lightData.forward);
        unL = mul(unL, transpose(lightToWorld));

        // TODO: This could be precomputed.
        float halfWidth  = lightData.size.x * 0.5;
        float halfHeight = lightData.size.y * 0.5;

        // Define the dimensions of the attenuation volume.
        // TODO: This could be precomputed.
        float  range      = lightData.range;
        float3 invHalfDim = rcp(float3(range + halfWidth,
                                    range + halfHeight,
                                    range));

        // Compute the light attenuation.
    #ifdef ELLIPSOIDAL_ATTENUATION
        // The attenuation volume is an axis-aligned ellipsoid s.t.
        // r1 = (r + w / 2), r2 = (r + h / 2), r3 = r.
        float intensity = EllipsoidalDistanceAttenuation(unL, invHalfDim,
                                                        lightData.rangeAttenuationScale,
                                                        lightData.rangeAttenuationBias);
    #else
        // The attenuation volume is an axis-aligned box s.t.
        // hX = (r + w / 2), hY = (r + h / 2), hZ = r.
        float intensity = BoxDistanceAttenuation(unL, invHalfDim,
                                                lightData.rangeAttenuationScale,
                                                lightData.rangeAttenuationBias);
    #endif

        intensity *= lightData.intensity;
        // Terminate if the shaded point is too far away.
        if (intensity != 0.0)
        {
            // lightData.diffuseDimmer  *= intensity;
            // lightData.specularDimmer *= intensity;

            // Translate the light s.t. the shaded point is at the origin of the coordinate system.
            lightData.positionRWS -= positionWS;

            float4x3 lightVerts;

            // TODO: some of this could be precomputed.
            lightVerts[0] = lightData.positionRWS + lightData.right * -halfWidth + lightData.up * -halfHeight; // LL
            lightVerts[1] = lightData.positionRWS + lightData.right * -halfWidth + lightData.up *  halfHeight; // UL
            lightVerts[2] = lightData.positionRWS + lightData.right *  halfWidth + lightData.up *  halfHeight; // UR
            lightVerts[3] = lightData.positionRWS + lightData.right *  halfWidth + lightData.up * -halfHeight; // LR

            // Rotate the endpoints into the local coordinate system.
            lightVerts = mul(lightVerts, transpose(preLightData.orthoBasisViewNormal));
            float3 ltcValue;

            // Evaluate the diffuse part
            // Polygon irradiance in the transformed configuration.
            float4x3 LD = mul(lightVerts, preLightData.ltcTransformDiffuse);
            float3 formFactorD;
#ifdef APPROXIMATE_POLY_LIGHT_AS_SPHERE_LIGHT
            formFactorD = PolygonFormFactor(LD);
            ltcValue = PolygonIrradianceFromVectorFormFactor(formFactorD);
#else
            ltcValue = PolygonIrradiance(LD, formFactorD);
#endif
            // ltcValue *= lightData.diffuseDimmer;
            ltcValue *= intensity;

            // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
            // See comment for specular magnitude, it apply to diffuse as well
            lighting.diffuse = preLightData.diffuseFGD * ltcValue;

            // Evaluate the specular part
            // Polygon irradiance in the transformed configuration.
            float4x3 LS = mul(lightVerts, preLightData.ltcTransformSpecular);
            float3 formFactorS;
#ifdef APPROXIMATE_POLY_LIGHT_AS_SPHERE_LIGHT
            formFactorS = PolygonFormFactor(LS);
            ltcValue = PolygonIrradianceFromVectorFormFactor(formFactorS);
#else
            ltcValue = PolygonIrradiance(LS);
#endif
            // ltcValue *= lightData.specularDimmer;
            ltcValue *= intensity;

            // We need to multiply by the magnitude of the integral of the BRDF
            // ref: http://advances.realtimerendering.com/s2016/s2016_ltc_fresnel.pdf
            // This value is what we store in specularFGD, so reuse it
            lighting.specular += preLightData.specularFGD * ltcValue;

            // Save ALU by applying 'lightData.color' only once.
            lighting.diffuse *= lightData.color;
            lighting.specular *= lightData.color;
        }
    }


    return lighting.diffuse + lighting.specular * (1.0f + preLightData.energyCompensation);
}

half3 EvaluateBSDF_Area(InputData inputData, PreLightData preLightData, AreaLightData lightData)
{
    if (lightData.lightType == GPULIGHTTYPE_TUBE)
    {
        return EvaluateBSDF_Line(inputData, preLightData, lightData);
    }
    else
    {
        return EvaluateBSDF_Rect(inputData, preLightData, lightData);
    }
}

#endif