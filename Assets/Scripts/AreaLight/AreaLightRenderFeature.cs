using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class AreaLightRenderPass : ScriptableRenderPass
{
    private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler("AreaLightRenderPass");
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        CommandBuffer cmd = CommandBufferPool.Get(m_ProfilingSampler.name);;
        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            PreIntegratedFGD.Instance.RenderInit(PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse, cmd);
            PreIntegratedFGD.Instance.Bind(cmd, PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse);
            LTCAreaLight.Instance.Bind(cmd);
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
        if (!m_Initialized)
        {
            m_Initialized = true;
            PreIntegratedFGD.Instance.Build(PreIntegratedFGD.FGDIndex.FGD_GGXAndDisneyDiffuse);
            LTCAreaLight.Instance.Build();
        }

        m_AreaLightRenderPass = new AreaLightRenderPass
        {
            renderPassEvent = renderPassEvent
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
        }
    }
}
