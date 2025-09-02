using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class AreaLightRenderPass : ScriptableRenderPass
{
    public int actualMaxAreaLightCount;
    private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler("AreaLightRenderPass");
    
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        if (renderingData.cameraData.camera.cameraType != CameraType.Game
            && renderingData.cameraData.camera.cameraType != CameraType.SceneView)
        {
            return;
        }
        
        CommandBuffer cmd = CommandBufferPool.Get(m_ProfilingSampler.name);;
        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            //Light
            PreIntegratedFGD.Instance.RenderInit(PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse, cmd);
            PreIntegratedFGD.Instance.Bind(cmd, PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse);
            LTCAreaLight.Instance.Bind(cmd);
            AreaLightManager.Instance.UpdateAreaLightData(cmd);
            
            //Shadow
            // UpdateShadowData(context, ref renderingData, cmd);
        }
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        CommandBufferPool.Release(cmd);
    }

    private void UpdateShadowData(ScriptableRenderContext context, ref RenderingData renderingData, CommandBuffer cmd)
    {
        //记录原来的vp矩阵
        Matrix4x4 viewMatrix = renderingData.cameraData.camera.worldToCameraMatrix;
        Matrix4x4 projectionMatrix = renderingData.cameraData.camera.projectionMatrix;
        
        // Matrix4x4 viewMatrix = renderingData.cameraData.GetViewMatrix();
        // Matrix4x4 projectionMatrix = renderingData.cameraData.GetGPUProjectionMatrix();
        
        int areaLightIndex = 0;
        ShaderTagId shaderTagId = new ShaderTagId("DepthOnly");
        foreach (var areaLight in AreaLightManager.Instance.areaLightSet)
        {
            if (areaLight.renderShadow)
            {
                RTHandle shadowMap = GetShadowMap(ref renderingData, cmd, areaLightIndex, (int)areaLight.shadowMapSize);
                ConfigureClear(ClearFlag.All, Color.black);
                ConfigureTarget(shadowMap);
                areaLight.GetViewProjectionMatrices(out Matrix4x4 view, out Matrix4x4 projection);
                cmd.SetViewProjectionMatrices(view, projection);
                context.ExecuteCommandBuffer(cmd);
                cmd.Clear(); 
                
                
                var sortingSettings = new SortingSettings()
                {
                    criteria = SortingCriteria.CommonOpaque
                };
                var drawingSettings = new DrawingSettings(shaderTagId, sortingSettings);
                var filteringSettings = new FilteringSettings(RenderQueueRange.all);
                ScriptableCullingParameters cullingParameters = areaLight.GetShadowMapCullingParameters();
                CullingResults cullingResults = context.Cull(ref cullingParameters);
                context.DrawRenderers(cullingResults, ref drawingSettings, ref filteringSettings);
            }
            
            areaLightIndex++;
            if (areaLightIndex > actualMaxAreaLightCount)
            {
                break;
            }
        }
        
        cmd.SetViewProjectionMatrices(viewMatrix, projectionMatrix);
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear(); 
    }
    
    private int[] m_AreaLightRenderShadowFlagsArray = new int[AreaLightManager.k_MaxAreaLightCount];
    private RTHandle[] m_AreaLightShadowMapArray = new RTHandle[AreaLightManager.k_MaxAreaLightCount];
    
    const GraphicsFormat k_DepthStencilFormat = GraphicsFormat.D32_SFloat_S8_UInt;
    const int k_DepthBufferBits = 32;
    private RTHandle GetShadowMap(ref RenderingData renderingData, CommandBuffer cmd, int areaLightIndex, int shadowMapSize)
    {
        RTHandle rtHandle = m_AreaLightShadowMapArray[areaLightIndex];

        var desc = renderingData.cameraData.cameraTargetDescriptor; 
        desc.width = shadowMapSize;
        desc.height = shadowMapSize;
        desc.depthStencilFormat = k_DepthStencilFormat;
        desc.depthBufferBits = k_DepthBufferBits;
        desc.graphicsFormat = GraphicsFormat.None;
        
        //var desc =  new RenderTextureDescriptor(shadowMapSize, shadowMapSize, RenderTextureFormat.Shadowmap, 24);
        // desc.depthStencilFormat = GraphicsFormat.D24_UNorm;
        RenderingUtils.ReAllocateIfNeeded(
            ref rtHandle,
            desc,
            name: "AreaLightShadowMap",
            filterMode: FilterMode.Point,
            wrapMode: TextureWrapMode.Clamp
        );
        m_AreaLightShadowMapArray[areaLightIndex] = rtHandle;
        return rtHandle;
    }
}

public class AreaLightRenderFeature : ScriptableRendererFeature
{
    [Range(1, 10)]
    public int maxAreaLightCount = 10;
    public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingOpaques;
    [InspectorReadOnly]
    public Shader preIntegratedFGDGGXDisneyDiffuseShader;
    [InspectorReadOnly]
    public Shader preIntegratedFGDCharlieFabricLambertShader;
    [InspectorReadOnly]
    public Shader preIntegratedFGDMarschnerShader;
    
    private bool m_Initialized = false;
    private AreaLightRenderPass m_AreaLightRenderPass;
    
    public override void Create()
    {
#if UNITY_EDITOR
        if (preIntegratedFGDGGXDisneyDiffuseShader == null)
        {
            preIntegratedFGDGGXDisneyDiffuseShader = Shader.Find("Hidden/AreaLight/PreIntegratedFGD_GGXDisneyDiffuse");
        }
        
        if (preIntegratedFGDCharlieFabricLambertShader == null)
        {
            preIntegratedFGDCharlieFabricLambertShader = Shader.Find("Hidden/AreaLight/PreIntegratedFGD_CharlieFabricLambert");
        }
        
        if (preIntegratedFGDMarschnerShader == null)
        {
            preIntegratedFGDMarschnerShader = Shader.Find("Hidden/AreaLight/PreIntegratedFGD_Marschner");
        }
        PreIntegratedFGD.SetPreIntegratedShaders(preIntegratedFGDGGXDisneyDiffuseShader, preIntegratedFGDCharlieFabricLambertShader, preIntegratedFGDMarschnerShader);
#endif
        AreaLightManager.Instance.Init(maxAreaLightCount);
        if (!m_Initialized)
        {
            m_Initialized = true;
            PreIntegratedFGD.Instance.Build(PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse);
            LTCAreaLight.Instance.Build();
        }

        m_AreaLightRenderPass = new AreaLightRenderPass
        {
            renderPassEvent = renderPassEvent,
            actualMaxAreaLightCount = maxAreaLightCount
        };
    }
    
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        renderer.EnqueuePass(m_AreaLightRenderPass);
    }

    protected override void Dispose(bool disposing)
    {
        if (m_Initialized)
        {
            PreIntegratedFGD.Instance.Cleanup(PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse);
            LTCAreaLight.Instance.Cleanup();
            m_Initialized = false;
        }
    }
}
