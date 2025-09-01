using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

public partial class AreaLight : MonoBehaviour
{
    public Camera m_ShadowmapCamera;
    private Transform m_ShadowmapCameraTransform;
    public enum TextureSize
    {
        x512 = 512,
        x1024 = 1024,
        x2048 = 2048,
        x4096 = 4096,
    }
    
    private float GetNearToCenter(float areaLightSizeY)
    {
        if (shadowFOVAngle == 0.0f)
        {
            return 0;
        }

        return areaLightSizeY * 0.5f / Mathf.Tan(shadowFOVAngle * 0.5f * Mathf.Deg2Rad);
    }

    public ScriptableCullingParameters GetShadowMapCullingParameters()
    {
        CreatShadowMapCameraIfNeeded();
        
        m_ShadowmapCamera.TryGetCullingParameters(out ScriptableCullingParameters cullingParameters);
        return cullingParameters;
    }

    private void CreatShadowMapCameraIfNeeded()
    {
        // Create the camera
        if (m_ShadowmapCamera == null)
        {
            GameObject go = new GameObject("ShadowMap Camera");
            go.AddComponent(typeof(Camera));
            m_ShadowmapCamera = go.GetComponent<Camera>();
            go.hideFlags = HideFlags.DontSave;
            m_ShadowmapCamera.enabled = false;
            m_ShadowmapCamera.clearFlags = CameraClearFlags.SolidColor;
            m_ShadowmapCamera.renderingPath = RenderingPath.Forward;
            // exp(EXPONENT) for ESM, white for VSM
            // m_ShadowmapCamera.backgroundColor = new Color(Mathf.Exp(EXPONENT), 0, 0, 0);
            m_ShadowmapCamera.backgroundColor = Color.white;
            m_ShadowmapCameraTransform = go.transform;
            m_ShadowmapCameraTransform.parent = transform;
            m_ShadowmapCameraTransform.localRotation = Quaternion.identity;
        }
    }

    public void GetViewProjectionMatrices(out Matrix4x4 view, out Matrix4x4 proj)
    {
        CreatShadowMapCameraIfNeeded();

        Vector2 lightSize = LightSize;
        if (shadowFOVAngle == 0.0f)
        {
            m_ShadowmapCamera.orthographic = true;
            m_ShadowmapCameraTransform.localPosition = Vector3.zero;
            m_ShadowmapCamera.nearClipPlane = 0;
            m_ShadowmapCamera.farClipPlane = shadowMapFarPlaneDistance;
            m_ShadowmapCamera.orthographicSize = 0.5f * lightSize.y;
            m_ShadowmapCamera.aspect = lightSize.x / lightSize.y;
        }
        else
        {
            m_ShadowmapCamera.orthographic = false;
            float near = GetNearToCenter(lightSize.y);
            m_ShadowmapCameraTransform.localPosition = -near * Vector3.forward;
            m_ShadowmapCamera.nearClipPlane = near;
            m_ShadowmapCamera.farClipPlane = near + shadowMapFarPlaneDistance;
            m_ShadowmapCamera.fieldOfView = shadowFOVAngle;
            m_ShadowmapCamera.aspect = lightSize.x / lightSize.y;
        }

        view = m_ShadowmapCamera.worldToCameraMatrix;
        proj = GL.GetGPUProjectionMatrix(m_ShadowmapCamera.projectionMatrix, false);
    }
}
