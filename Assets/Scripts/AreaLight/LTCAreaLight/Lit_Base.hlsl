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
    // float energyCompensation;

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

PreLightData GetPreLightData(float3 positionWS, BSDFData bsdfData)
{
    half3 V = GetWorldSpaceNormalizeViewDir(positionWS);
    PreLightData preLightData;
    ZERO_INITIALIZE(PreLightData, preLightData);

    float3 N = bsdfData.normalWS;
    preLightData.NdotV = dot(N, V);
    float perceptualRoughness = bsdfData.perceptualRoughness;

    float clampedNdotV = ClampNdotV(preLightData.NdotV);

    //屏蔽虹彩效果
    // // We modify the bsdfData.fresnel0 here for iridescence
    // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_IRIDESCENCE))
    // {
    //     float viewAngle = clampedNdotV;
    //     float topIor = 1.0; // Default is air
    //     if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    //     {
    //         topIor = lerp(1.0, CLEAR_COAT_IOR, bsdfData.coatMask);
    //         // HACK: Use the reflected direction to specify the Fresnel coefficient for pre-convolved envmaps
    //         if (bsdfData.coatMask != 0.0f) // We must make sure that effect is neutral when coatMask == 0
    //             viewAngle = sqrt(1.0 + Sq(1.0 / topIor) * (Sq(dot(bsdfData.normalWS, V)) - 1.0));
    //     }
    //
    //     if (bsdfData.iridescenceMask > 0.0)
    //     {
    //         bsdfData.fresnel0 = lerp(bsdfData.fresnel0, EvalIridescence(topIor, viewAngle, bsdfData.iridescenceThickness, bsdfData.fresnel0), bsdfData.iridescenceMask);
    //     }
    // }

    //屏蔽清漆
    // // We modify the bsdfData.fresnel0 here for clearCoat
    // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    // {
    //     // Fresnel0 is deduced from interface between air and material (Assume to be 1.5 in Unity, or a metal).
    //     // but here we go from clear coat (1.5) to material, we need to update fresnel0
    //     // Note: Schlick is a poor approximation of Fresnel when ieta is 1 (1.5 / 1.5), schlick target 1.4 to 2.2 IOR.
    //     bsdfData.fresnel0 = lerp(bsdfData.fresnel0, ConvertF0ForAirInterfaceToF0ForClearCoat15(bsdfData.fresnel0), bsdfData.coatMask);
    //
    //     preLightData.coatPartLambdaV = GetSmithJointGGXPartLambdaV(clampedNdotV, CLEAR_COAT_ROUGHNESS);
    //     preLightData.coatIblR = reflect(-V, N);
    //     preLightData.coatIblF = F_Schlick(CLEAR_COAT_F0, clampedNdotV) * bsdfData.coatMask;
    //     preLightData.coatReflectionWeight = 0.0;
    // }

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
//     preLightData.energyCompensation = 1.0 / specularReflectivity - 1.0;
// #else
//     preLightData.energyCompensation = 0.0;
// #endif // LIT_USE_GGX_ENERGY_COMPENSATION

    // float3 iblN;

    // // We avoid divergent evaluation of the GGX, as that nearly doubles the cost.
    // // If the tile has anisotropy, all the pixels within the tile are evaluated as anisotropic.
    // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_ANISOTROPY))
    // {
    //     float TdotV = dot(bsdfData.tangentWS,   V);
    //     float BdotV = dot(bsdfData.bitangentWS, V);
    //
    //     preLightData.partLambdaV = GetSmithJointGGXAnisoPartLambdaV(TdotV, BdotV, clampedNdotV, bsdfData.roughnessT, bsdfData.roughnessB);
    //
    //     // perceptualRoughness is use as input and output here
    //     GetGGXAnisotropicModifiedNormalAndRoughness(bsdfData.bitangentWS, bsdfData.tangentWS, N, V, bsdfData.anisotropy, preLightData.iblPerceptualRoughness, iblN, preLightData.iblPerceptualRoughness);
    // }
    // else
    // {
    //     preLightData.partLambdaV = GetSmithJointGGXPartLambdaV(clampedNdotV, bsdfData.roughnessT);
    //     iblN = N;
    // }
    //
    // preLightData.iblR = reflect(-V, iblN);

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

    //屏蔽清漆
    // preLightData.ltcTransformCoat = 0.0;
    // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
    // {
    //     float2 uv = LTC_LUT_OFFSET + LTC_LUT_SCALE * float2(CLEAR_COAT_PERCEPTUAL_ROUGHNESS, cosThetaParam);
    //
    //     // Get the inverse LTC matrix for GGX
    //     // Note we load the matrix transpose (avoid to have to transpose it in shader)
    //     preLightData.ltcTransformCoat._m22 = 1.0;
    //     preLightData.ltcTransformCoat._m00_m02_m11_m20 = SAMPLE_TEXTURE2D_ARRAY_LOD(_LtcData, s_linear_clamp_sampler, uv, LTCLIGHTINGMODEL_GGX, 0);
    // }

    //屏蔽折射
//     // refraction (forward only)
// #if HAS_REFRACTION
//     RefractionModelResult refraction = REFRACTION_MODEL(V, posInput, bsdfData);
//     preLightData.transparentRefractV = refraction.rayWS;
//     preLightData.transparentPositionWS = refraction.positionWS;
//     preLightData.transparentTransmittance = exp(-bsdfData.absorptionCoefficient * refraction.dist);
//
//     // Empirical remap to try to match a bit the refraction probe blurring for the fallback
//     // Use IblPerceptualRoughness so we can handle approx of clear coat.
//     preLightData.transparentSSMipLevel = PositivePow(preLightData.iblPerceptualRoughness, 1.3) * uint(max(_ColorPyramidLodCount - 1, 0));
// #endif

    return preLightData;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Line - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

half3 EvaluateBSDF_Line(PositionInputs posInput, PreLightData preLightData, AreaLightData lightData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;

// #ifdef LIT_DISPLAY_REFERENCE_AREA
    //这个是直接数值积分的方式，不是LTC，测试对比用
    // IntegrateBSDF_LineRef(V, positionWS, preLightData, lightData, bsdfData,
    //                       lighting.diffuse, lighting.specular);
// #else
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
        // lightData.diffuseDimmer  *= intensity;
        // lightData.specularDimmer *= intensity;

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

        //透射部分暂时不需要
        // UNITY_BRANCH if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_TRANSMISSION))
        // {
        //     // Flip the view vector and the normal. The bitangent stays the same.
        //     float3x3 flipMatrix = float3x3(-1,  0,  0,
        //                                     0,  1,  0,
        //                                     0,  0, -1);
        //
        //     // Use the Lambertian approximation for performance reasons.
        //     // The matrix multiplication should not generate any extra ALU on GCN.
        //     // TODO: double evaluation is very inefficient! This is a temporary solution.
        //     ltcValue  = LTCEvaluate(P1, P2, B, mul(flipMatrix, k_identity3x3));
        //     // ltcValue *= lightData.diffuseDimmer;
        //     ltcValue *= intensity;
        //     // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
        //     // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
        //     lighting.diffuse += bsdfData.transmittance * ltcValue;
        // }

        // Evaluate the specular part
        ltcValue = LTCEvaluate(P1, P2, B, preLightData.ltcTransformSpecular);
        // ltcValue *= lightData.specularDimmer;
        ltcValue *= intensity;
        // We need to multiply by the magnitude of the integral of the BRDF
        // ref: http://advances.realtimerendering.com/s2016/s2016_ltc_fresnel.pdf
        // This value is what we store in specularFGD, so reuse it
        lighting.specular = preLightData.specularFGD * ltcValue;

        //清漆部分暂时不需要
        // // Evaluate the coat part
        // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
        // {
        //     ltcValue = LTCEvaluate(P1, P2, B, preLightData.ltcTransformCoat);
        //     // ltcValue *= lightData.specularDimmer;
        //     ltcValue *= intensity;
        //     // For clear coat we don't fetch specularFGD we can use directly the perfect fresnel coatIblF
        //     lighting.diffuse *= (1.0 - preLightData.coatIblF);
        //     lighting.specular *= (1.0 - preLightData.coatIblF);
        //     lighting.specular += preLightData.coatIblF * ltcValue;
        // }

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

    // #endif // LIT_DISPLAY_REFERENCE_AREA

    return lighting.diffuse + lighting.specular;
}

//-----------------------------------------------------------------------------
// EvaluateBSDF_Rect - Approximation with Linearly Transformed Cosines
//-----------------------------------------------------------------------------

// #define ELLIPSOIDAL_ATTENUATION

half3 EvaluateBSDF_Rect(PositionInputs posInput, PreLightData preLightData, AreaLightData lightData)
{
    DirectLighting lighting;
    ZERO_INITIALIZE(DirectLighting, lighting);

    float3 positionWS = posInput.positionWS;

#if SHADEROPTIONS_BARN_DOOR
    // Apply the barn door modification to the light data
    RectangularLightApplyBarnDoor(lightData, positionWS);
#endif

// #ifdef LIT_DISPLAY_REFERENCE_AREA
//     IntegrateBSDF_AreaRef(V, positionWS, preLightData, lightData, bsdfData,
//                           lighting.diffuse, lighting.specular);
// #else
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

            //TODO: Cookie
//             // Only apply cookie if there is one
//             if ( lightData.cookieMode != COOKIEMODE_NONE )
//             {
// #ifndef APPROXIMATE_POLY_LIGHT_AS_SPHERE_LIGHT
//                 formFactorD = PolygonFormFactor(LD);
// #endif
//                 ltcValue *= SampleAreaLightCookie(lightData.cookieScaleOffset, LD, formFactorD);
//             }

            // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
            // See comment for specular magnitude, it apply to diffuse as well
            lighting.diffuse = preLightData.diffuseFGD * ltcValue;

            //透射部分暂时不需要
            // UNITY_BRANCH if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_TRANSMISSION))
            // {
            //     // Flip the view vector and the normal. The bitangent stays the same.
            //     float3x3 flipMatrix = float3x3(-1,  0,  0,
            //                                     0,  1,  0,
            //                                     0,  0, -1);
            //
            //     // Use the Lambertian approximation for performance reasons.
            //     // The matrix multiplication should not generate any extra ALU on GCN.
            //     float3x3 ltcTransform = mul(flipMatrix, k_identity3x3);
            //
            //     // Polygon irradiance in the transformed configuration.
            //     // TODO: double evaluation is very inefficient! This is a temporary solution.
            //     float4x3 LTD = mul(lightVerts, ltcTransform);
            //     ltcValue  = PolygonIrradiance(LTD);
            //     // ltcValue *= lightData.diffuseDimmer;
            //     ltcValue *= intensity;
            //
            //     //TODO: Cookie
            //     // // Only apply cookie if there is one
            //     // if ( lightData.cookieMode != COOKIEMODE_NONE )
            //     // {
            //     //     // Compute the cookie data for the transmission diffuse term
            //     //     float3 formFactorTD = PolygonFormFactor(LTD);
            //     //     ltcValue *= SampleAreaLightCookie(lightData.cookieScaleOffset, LTD, formFactorTD);
            //     // }
            //
            //     // We use diffuse lighting for accumulation since it is going to be blurred during the SSS pass.
            //     // We don't multiply by 'bsdfData.diffuseColor' here. It's done only once in PostEvaluateBSDF().
            //     lighting.diffuse += bsdfData.transmittance * ltcValue;
            // }

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

            //TODO: Cookie
//             // Only apply cookie if there is one
//             if ( lightData.cookieMode != COOKIEMODE_NONE)
//             {
//                 // Compute the cookie data for the specular term
// #ifndef APPROXIMATE_POLY_LIGHT_AS_SPHERE_LIGHT
//                 formFactorS =  PolygonFormFactor(LS);
// #endif
//                 ltcValue *= SampleAreaLightCookie(lightData.cookieScaleOffset, LS, formFactorS, bsdfData.perceptualRoughness);
//             }

            // We need to multiply by the magnitude of the integral of the BRDF
            // ref: http://advances.realtimerendering.com/s2016/s2016_ltc_fresnel.pdf
            // This value is what we store in specularFGD, so reuse it
            lighting.specular += preLightData.specularFGD * ltcValue;

            //暂时不需要清漆部分
            // // Evaluate the coat part
            // if (HasFlag(bsdfData.materialFeatures, MATERIALFEATUREFLAGS_LIT_CLEAR_COAT))
            // {
            //     float4x3 LSCC = mul(lightVerts, preLightData.ltcTransformCoat);
            //     ltcValue = PolygonIrradiance(LSCC);
            //     // ltcValue *= lightData.specularDimmer;
            //     ltcValue *= intensity;
            //     //TODO: Cookie
            //     // // Only apply cookie if there is one
            //     // if ( lightData.cookieMode != COOKIEMODE_NONE )
            //     // {
            //     //     // Compute the cookie data for the specular term
            //     //     float3 formFactorS =  PolygonFormFactor(LSCC);
            //     //     ltcValue *= SampleAreaLightCookie(lightData.cookieScaleOffset, LSCC, formFactorS);
            //     // }
            //     // For clear coat we don't fetch specularFGD we can use directly the perfect fresnel coatIblF
            //     lighting.diffuse *= (1.0 - preLightData.coatIblF);
            //     lighting.specular *= (1.0 - preLightData.coatIblF);
            //     lighting.specular += preLightData.coatIblF * ltcValue;
            // }

            //TODO: Shadow
            // Raytracing shadow algorithm require to evaluate lighting without shadow, so it defined SKIP_RASTERIZED_AREA_SHADOWS
            // This is only present in Lit Material as it is the only one using the improved shadow algorithm.
        // #ifndef SKIP_RASTERIZED_AREA_SHADOWS
        //     SHADOW_TYPE shadow = EvaluateShadow_RectArea(lightLoopContext, posInput, lightData, builtinData, bsdfData.normalWS, normalize(lightData.positionRWS), length(lightData.positionRWS));
        //     lightData.color.rgb *= ComputeShadowColor(shadow, lightData.shadowTint, lightData.penumbraTint);
        // #endif

            // Save ALU by applying 'lightData.color' only once.
            lighting.diffuse *= lightData.color;
            lighting.specular *= lightData.color;

        #ifdef DEBUG_DISPLAY
            if (_DebugLightingMode == DEBUGLIGHTINGMODE_LUX_METER)
            {
                // Only lighting, not BSDF
                // Apply area light on lambert then multiply by PI to cancel Lambert
                lighting.diffuse = PolygonIrradiance(mul(lightVerts, k_identity3x3));
                lighting.diffuse *= PI * lightData.diffuseDimmer;
            }
        #endif
        }
    }

// #endif // LIT_DISPLAY_REFERENCE_AREA

    return lighting.diffuse + lighting.specular;
}

half3 EvaluateBSDF_Area(PositionInputs posInput,
    PreLightData preLightData, AreaLightData lightData)
{
    if (lightData.lightType == GPULIGHTTYPE_TUBE)
    {
        return EvaluateBSDF_Line(posInput, preLightData, lightData);
    }
    else
    {
        return EvaluateBSDF_Rect(posInput, preLightData, lightData);
    }
}

#endif