Shader "Unlit/AreaLightSource"
{
    Properties
    {
        [HideInInspector]_LightColor("Light Color", Color) = (1,1,1,1)
    }
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
            "LightMode" = "UniversalForward"
        }
        LOD 100
        
        Cull Front
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            half4 _LightColor;
            
            struct Attributes
            {
                float3 posOS : POSITION;
            };

            struct Varyings
            {
                float4 posCS : SV_POSITION;                
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.posCS = GetVertexPositionInputs(input.posOS).positionCS;
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                return _LightColor;                
            }
            ENDHLSL
        }
    }
}
