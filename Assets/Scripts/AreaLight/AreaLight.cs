using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[RequireComponent(typeof(MeshRenderer)),RequireComponent(typeof(MeshRenderer)), ExecuteAlways]
public class AreaLight : MonoBehaviour
{
    public AreaLightType areaLightType = AreaLightType.RECT;
    [Min(0.0f)]
    public float intensity = 1.0f;
    [Min(0.0f)]
    public float range = 10;
    [Min(0.0f)]
    public float rangeAttenuationScale = 1;
    [Min(0.0f)]
    public float rangeAttenuationBias = 1;
    public Color color = Color.white;

    private Transform m_Transform;

    private void OnEnable()
    {
        AreaLightManager.Instance.Add(this);
    }

    private void OnDisable()
    {
        AreaLightManager.Instance.Remove(this);
    }

    private MeshRenderer m_MeshRenderer;
    private Mesh m_Mesh;
    
    public void GetPosAndSize(out Vector3 pos, out Vector2 size)
    {
        if (m_Transform == null)
        {
            m_Transform = transform;
        }
        pos = m_Transform.position;
        size = Vector2.zero;

        //用这个是包围盒的尺寸，如果mesh旋转了，尺寸会不对
        // if (m_MeshRenderer == null)
        // {
        //     m_MeshRenderer = GetComponent<MeshRenderer>();
        // }
        //size = m_MeshRenderer.bounds.size;

        if (m_Mesh == null)
        {
            m_Mesh = GetComponent<MeshFilter>().sharedMesh;
        }
        
        Vector3 localSize = m_Mesh.bounds.size;
        Vector3 scale = transform.lossyScale; // 世界缩放
        size = Vector3.Scale(localSize, scale); // 按分量相乘
    }

    public void GetDirection(out Vector3 up, out Vector3 right, out Vector3 forward)
    {
        if (m_Transform == null)
        {
            m_Transform = transform;
        }
        up = m_Transform.up;
        right = m_Transform.right;
        forward = m_Transform.forward;
    }

    private Material m_Material;
    
    private readonly int _LightColor = Shader.PropertyToID("_LightColor");
    private void OnValidate()
    {
        if (m_Material == null)
        {
            if (m_MeshRenderer == null)
            {
                m_MeshRenderer = GetComponent<MeshRenderer>();
            }
            
            m_Material = m_MeshRenderer.sharedMaterial;
        }
        
        m_Material.SetColor(_LightColor, color * intensity);
    }
}
