using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class AreaLightRenderPass : ScriptableRenderPass
{
    public int maxAreaLightCount;
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
            AreaLightManager.Instance.UpdateShadowData(context, ref renderingData, cmd);
            
        }
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        CommandBufferPool.Release(cmd);
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
            maxAreaLightCount = maxAreaLightCount
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
