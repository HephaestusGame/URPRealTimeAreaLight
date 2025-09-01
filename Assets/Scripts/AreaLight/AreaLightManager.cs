using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// 与shader保持一致
/// </summary>
public enum AreaLightType
{
    TUBE = 5,
    RECT = 6
}

public class AreaLightManager
{
    #region Shader properties ID

    private readonly int _AreaLightCount = Shader.PropertyToID("_AreaLightCount");
    private readonly int _AreaLightTypeArray = Shader.PropertyToID("_AreaLightTypeArray");
    private readonly int _AreaLightRangeAndIntensityArray = Shader.PropertyToID("_AreaLightRangeAndIntensityArray");
    private readonly int _AreaLightSizeArray  = Shader.PropertyToID("_AreaLightSizeArray");
    private readonly int _AreaLightColorArray = Shader.PropertyToID("_AreaLightColorArray");
    private readonly int _AreaLightPositionArray  = Shader.PropertyToID("_AreaLightPositionArray");
    private readonly int _AreaLightDirectionUpArray = Shader.PropertyToID("_AreaLightDirectionUpArray");
    private readonly int _AreaLightDirectionRightArray = Shader.PropertyToID("_AreaLightDirectionRightArray");
    private readonly int _AreaLightDirectionForwardArray = Shader.PropertyToID("_AreaLightDirectionForwardArray");

    #endregion
    
    private HashSet<AreaLight> m_AreaLightsSet = new HashSet<AreaLight>();
    
    private static AreaLightManager m_Instance;
    public static AreaLightManager Instance
    {
        get
        {
            if (m_Instance == null)
            {
                m_Instance = new AreaLightManager();
            }
            
            return m_Instance;
        }
    }

    //需要与Shader中一致
    private const int k_MaxAreaLightCount = 10;
    private int m_ActualMaxAreaLightCount;
    private float[] m_AreaLightTypeArray;
    private Vector4[] m_AreaLightRangeAndIntensityArray;
    private Vector4[] m_AreaLightSizeArray;
    private Vector4[] m_AreaLightColorArray;
    private Vector4[] m_AreaLightPositionArray;
    private Vector4[] m_AreaLightDirectionUpArray;
    private Vector4[] m_AreaLightDirectionRightArray;
    private Vector4[] m_AreaLightDirectionForwardArray;
    
    public void Init(int maxAreaLightCount)
    {
        m_ActualMaxAreaLightCount = maxAreaLightCount;
        m_AreaLightTypeArray = new float[k_MaxAreaLightCount];
        m_AreaLightRangeAndIntensityArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightSizeArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightColorArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightPositionArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightDirectionUpArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightDirectionRightArray = new Vector4[k_MaxAreaLightCount];
        m_AreaLightDirectionForwardArray = new Vector4[k_MaxAreaLightCount];
    }

    public void Add(AreaLight areaLight)
    {
        m_AreaLightsSet.Add(areaLight);
    }

    public void Remove(AreaLight areaLight)
    {
        m_AreaLightsSet.Remove(areaLight);
    }
    
    public void UpdateAreaLightData(CommandBuffer cmd)
    {
        int areaLightCount = 0;
        foreach (var areaLight in m_AreaLightsSet)
        {
            m_AreaLightTypeArray[areaLightCount] = (int)areaLight.areaLightType;
            m_AreaLightRangeAndIntensityArray[areaLightCount] = new Vector4(
                areaLight.range,
                areaLight.rangeAttenuationScale,
                areaLight.rangeAttenuationBias,
                areaLight.intensity);
            areaLight.GetPosAndSize(out Vector3 areaLightPos, out Vector2 areaLightSize);
            m_AreaLightSizeArray[areaLightCount] = areaLightSize;
            m_AreaLightPositionArray[areaLightCount] = areaLightPos;
            m_AreaLightColorArray[areaLightCount] = areaLight.color;
            
            areaLight.GetDirection(out Vector3 up, out Vector3 right, out Vector3 forward);
            m_AreaLightDirectionUpArray[areaLightCount] = up;
            m_AreaLightDirectionRightArray[areaLightCount] = right;
            m_AreaLightDirectionForwardArray[areaLightCount] = forward;
            
            areaLightCount++;
            if (areaLightCount > m_ActualMaxAreaLightCount)
            {
                break;
            }
        }
        
        cmd.SetGlobalInt(_AreaLightCount, areaLightCount);
        cmd.SetGlobalFloatArray(_AreaLightTypeArray, m_AreaLightTypeArray);
        cmd.SetGlobalVectorArray(_AreaLightRangeAndIntensityArray, m_AreaLightRangeAndIntensityArray);
        cmd.SetGlobalVectorArray(_AreaLightSizeArray, m_AreaLightSizeArray);
        cmd.SetGlobalVectorArray(_AreaLightPositionArray, m_AreaLightPositionArray);
        cmd.SetGlobalVectorArray(_AreaLightColorArray, m_AreaLightColorArray);
        cmd.SetGlobalVectorArray(_AreaLightDirectionUpArray, m_AreaLightDirectionUpArray);
        cmd.SetGlobalVectorArray(_AreaLightDirectionRightArray, m_AreaLightDirectionRightArray);
        cmd.SetGlobalVectorArray(_AreaLightDirectionForwardArray, m_AreaLightDirectionForwardArray);
    }


    private int[] m_AreaLightRenderShadowFlagsArray = new int[k_MaxAreaLightCount];
    private RTHandle[] m_AreaLightShadowMapArray = new RTHandle[k_MaxAreaLightCount];
    
    public void UpdateShadowData(ScriptableRenderContext context, ref RenderingData renderingData, CommandBuffer cmd)
    {
        //记录原来的vp矩阵
        Matrix4x4 viewMatrix = renderingData.cameraData.camera.worldToCameraMatrix;
        Matrix4x4 projectionMatrix = renderingData.cameraData.camera.projectionMatrix;
        
        // Matrix4x4 viewMatrix = renderingData.cameraData.GetViewMatrix();
        // Matrix4x4 projectionMatrix = renderingData.cameraData.GetGPUProjectionMatrix();
        
        int areaLightIndex = 0;
        ShaderTagId shaderTagId = new ShaderTagId("DepthOnly");
        foreach (var areaLight in m_AreaLightsSet)
        {
            if (areaLight.renderShadow)
            {
                RTHandle shadowMap = GetShadowMap(ref renderingData, cmd, areaLightIndex, (int)areaLight.shadowMapSize);
                ScriptableCullingParameters cullingParameters = areaLight.GetShadowMapCullingParameters();


                
                CullingResults cullingResults = context.Cull(ref cullingParameters);
                
                cmd.SetRenderTarget(shadowMap);
                cmd.ClearRenderTarget(true, true, Color.white);
                areaLight.GetViewProjectionMatrices(out Matrix4x4 view, out Matrix4x4 projection);
                cmd.SetViewProjectionMatrices(view, projection);
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear(); 
                
                var sortingSettings = new SortingSettings()
                {
                    // criteria = SortingCriteria.CommonOpaque
                };
                var drawingSettings = new DrawingSettings(shaderTagId, sortingSettings);
                var filteringSettings = new FilteringSettings(RenderQueueRange.all);
                context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
            }
            
            areaLightIndex++;
            if (areaLightIndex > m_ActualMaxAreaLightCount)
            {
                break;
            }
        }
        
        cmd.SetViewProjectionMatrices(viewMatrix, projectionMatrix);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear(); 
    }

    private RTHandle GetShadowMap(ref RenderingData renderingData, CommandBuffer cmd, int areaLightIndex, int shadowMapSize)
    {
        RTHandle rtHandle = m_AreaLightShadowMapArray[areaLightIndex];
        
        // int texID = Shader.PropertyToID("AreaLightShadowMap");
        // var cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;
        // cameraTargetDescriptor.width = shadowMapSize;
        // cameraTargetDescriptor.height = shadowMapSize;
        // cameraTargetDescriptor.depthBufferBits = 24;
        // cmd.GetTemporaryRT(texID, cameraTargetDescriptor);
        // if (rtHandle == null)
        // {
        //     rtHandle = RTHandles.Alloc(new RenderTargetIdentifier(texID));
        // }
        
        var desc = new RenderTextureDescriptor(shadowMapSize, shadowMapSize, RenderTextureFormat.Depth, 24);
        RenderingUtils.ReAllocateIfNeeded(
            ref rtHandle, 
            desc, 
            name:"AreaLightShadowMap", 
            filterMode: FilterMode.Bilinear, 
            wrapMode: TextureWrapMode.Clamp
            );
        m_AreaLightShadowMapArray[areaLightIndex] = rtHandle;
        return rtHandle;
    }
}
