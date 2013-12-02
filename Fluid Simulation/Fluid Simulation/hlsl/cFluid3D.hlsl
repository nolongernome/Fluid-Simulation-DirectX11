/***************************************************************
cFluid3D.hlsl: Contains the necessary compute shaders to
handle 3D fluid simulation by numerically solving the 
Navier-Stokes equations. Also provides a rendering function that
uses ray-marching to render a 3D texture

Author: Valentin Hinov
Date: 09/11/2013
***************************************************************/
#pragma warning(disable : 3203)	// disable signed/unsigned mismatch warning

#define NUM_THREADS_X 16
#define NUM_THREADS_Y 4
#define NUM_THREADS_Z 4

// Constant buffers
cbuffer InputBufferGeneral : register (b0) {
	float fTimeStep;			// Used for AdvectComputeShader, BuoyancyComputeShader
	
	float fBuoyancy;			// Used for BuoyancyComputeShader
	float fDensityWeight;		// Used for BuoyancyComputeShader
	float fAmbientTemperature;  // Used for BuoyancyComputeShader

	float3 vDimensions;
	float  padding10;
	
	float3 vEyePos;	
	float  fZoom;

	uint2  vViewportDimensions;
	float2 padding11;

	float4x4 mRotationMatrix;	// 128 bytes
};

cbuffer InputBufferDissipation : register (b1) {
	float fDissipation;			// Used for AdvectComputeShader
	float3 padding1;			// pad to 16 bytes
}

cbuffer InputBufferImpulse : register (b2) {
	float4 vPoint;				// Used for ImpulseComputeShader
	float4 vFillColor;			// Used for ImpulseComputeShader
	float fRadius;				// Used for ImpulseComputeShader
	float3 padding2;			// pad to 48 bytes
}


// Samplers
SamplerState linearSampler : register (s0);

// Texture Inputs
Texture3D<float3>	velocity : register (t0);	// Used for AdvectComputeShader, DivergenceComputeShader, BuoyancyComputeShader, SubtractGradientComputeShader
Texture3D<float3>	advectionTargetA : register (t1); // Used for AdvectComputeShader, AdvectBackwardComputeShader
Texture3D<float3>	advectionTargetB : register (t2); // User for AdvectMacCormackComputeShader
Texture3D<float3>	advectionTargetC : register (t3); // User for AdvectMacCormackComputeShader
RWTexture3D<float3> advectionResult : register (u0); // Used for AdvectComputeShader, AdvectBackwardComputeShader, AdvectMacCormackComputeShader

Texture3D<float>	temperature : register (t1); // Used for BuoyancyComputeShader
Texture3D<float>	density : register (t2); // Used for BuoyancyComputeShader
RWTexture3D<float3> buoyancyResult : register (u0); // Used for BuoyancyComputeShader

Texture3D<float3>   impulseInitial : register (t0); // Used for ImpulseComputeShader
RWTexture3D<float3> impulseResult : register (u0); // Used for ImpulseComputeShader

Texture3D<float>     divergence   : register (t0);  // Used for JacobiComputeShader
RWTexture3D<float>   divergenceResult : register (u0);  // Used for DivergenceComputeShader

Texture3D<float>   pressure : register (t1);  // Used for JacobiComputeShader, SubtractGradientComputeShader
RWTexture3D<float> pressureResult : register (u0); // Used for JacobiComputeShader

RWTexture3D<float3> velocityResult : register (u0); // Used for SubtractGradientComputeShader

Texture3D<float>	renderInputTexture : register (t0);
RWTexture2D<float4> renderResult : register (u0);

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// Advect the speed by sampling at pos - deltaTime*velocity
void AdvectComputeShader( uint3 i : SV_DispatchThreadID ) {
	// advect by trace back
	float3 prevPos = i - fTimeStep * velocity[i];
	prevPos = (prevPos+0.5f)/vDimensions;

	float3 result = advectionTargetA.SampleLevel(linearSampler, prevPos, 0);

	advectionResult[i] = result;//*fDissipation;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// Advect the speed by sampling at pos + deltaTime*velocity
void AdvectBackwardComputeShader( uint3 i : SV_DispatchThreadID ) {
	// advect by trace forward
	float3 prevPos = i + fTimeStep * velocity[i];
	prevPos = (prevPos+0.5f)/vDimensions;

	float3 result = advectionTargetA.SampleLevel(linearSampler, prevPos, 0);

	advectionResult[i] = result;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// Advect the speed by using the two intermediate semi-Lagrangian steps to achieve higher-order accuracy
void AdvectMacCormackComputeShader( uint3 i : SV_DispatchThreadID ) {
	// advect by trace back
	float3 prevPos = i - fTimeStep * velocity[i];
	uint3 j = (uint3) prevPos;

	prevPos = (prevPos+0.5f)/vDimensions;

	// Get the values of nodes that contribute to the interpolated value.  
	float3 r0 = advectionTargetA[j + uint3(0,0,0)];
	float3 r1 = advectionTargetA[j + uint3(1,0,0)];
	float3 r2 = advectionTargetA[j + uint3(0,1,0)];
	float3 r3 = advectionTargetA[j + uint3(1,1,0)];
	float3 r4 = advectionTargetA[j + uint3(0,0,1)];
	float3 r5 = advectionTargetA[j + uint3(1,0,1)];
	float3 r6 = advectionTargetA[j + uint3(0,1,1)];
	float3 r7 = advectionTargetA[j + uint3(1,1,1)];

	// Determine a valid range for the result.
	float3 lmin = min(r0,min(r1,min(r2, min(r3, min(r4, min(r5, min(r6, r7)))))));
	float3 lmax = max(r0,max(r1,max(r2, max(r3, max(r4, max(r5, max(r6, r7)))))));

	// Perform final advection, combining values from intermediate advection steps.
	// based on http://http.developer.nvidia.com/GPUGems3/elementLinks/0640equ01.jpg
	float3 phi_n_1_hat = advectionTargetA.SampleLevel(linearSampler,prevPos, 0);
	float3 phi_n_hat = advectionTargetB.SampleLevel(linearSampler,prevPos, 0);
	float3 phi_n = advectionTargetC.SampleLevel(linearSampler,prevPos, 0);
		 
	float3 s = phi_n_1_hat + 0.5f*(phi_n - phi_n_hat);

	// clamp results to desired range
	s = clamp(s,lmin,lmax);

	advectionResult[i] = s*fDissipation;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// Create upward force by using the temperature difference
void BuoyancyComputeShader( uint3 i : SV_DispatchThreadID ) {
	float temperatureVal = temperature[i];
	float densityVal = density[i];

	float3 result = velocity[i];

	if (temperatureVal > fAmbientTemperature) {
		result += (fTimeStep * (temperatureVal - fAmbientTemperature) * fBuoyancy - (densityVal * fDensityWeight) ) * float3(0.0f, -1.0f, 0.0f);
	}
	buoyancyResult[i] = result;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// Adds impulse depending on point of interaction, also used for rendering obstacles
void ImpulseComputeShader( uint3 i : SV_DispatchThreadID ) {
	float d = distance(vPoint.xyz,i);

	if (d < fRadius) {
		//float a = (fRadius - d) * 0.5f;
		//a = min(a,1.0f);
		impulseResult[i] = vFillColor.xyz;
	}
	else
		impulseResult[i] = impulseInitial[i];
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// calculate the velocity divergence
void DivergenceComputeShader( uint3 i : SV_DispatchThreadID ) {

	uint3 coordT = i + uint3(0, 1, 0);
	uint3 coordB = i - uint3(0, 1, 0);
	uint3 coordR = i + uint3(1, 0, 0);
	uint3 coordL = i - uint3(1, 0, 0);
	uint3 coordU = i + uint3(0, 0, 1);
	uint3 coordD = i - uint3(0, 0, 1);

	// Find neighbouring velocities
	float3 vT = velocity[coordT];
	float3 vB = velocity[coordB];
	float3 vR = velocity[coordR];
	float3 vL = velocity[coordL];
	float3 vU = velocity[coordU];
	float3 vD = velocity[coordD];

	// Enforce boundaries
	if (coordT.y > vDimensions.y - 1) {
		vT.y = 0.0f;
	}
	if (coordB.y < 1) {
		vB.y = 0.0f;
	}
	if (coordR.x > vDimensions.x - 1) {
		vR.x = 0.0f;
	}
	if (coordL.x < 1) {
		vL.x = 0.0f;
	}
	if (coordU.z > vDimensions.z - 1) {
		vU.z = 0.0f;
	}
	if (coordD.z < 1) {
		vD.z = 0.0f;
	}

	float result = 0.5f * (vR.x - vL.x + vT.y - vB.y + vU.z - vD.z);

	divergenceResult[i] = result;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// jacobi shader to compute the gradient pressure field
void JacobiComputeShader( uint3 i : SV_DispatchThreadID ) {
	uint3 coordT = uint3(i.x, min(i.y+1,vDimensions.y-1), i.z);
	uint3 coordB = uint3(i.x, max(i.y-1,1), i.z);
	uint3 coordR = uint3(min(i.x+1,vDimensions.x-1), i.y, i.z);
	uint3 coordL = uint3(max(i.x-1,1), i.y, i.z);
	uint3 coordU = uint3(i.x, i.y, min(i.z+1,vDimensions.z-1));
	uint3 coordD = uint3(i.x, i.y, max(i.z-1,1));

	float xC = pressure[i];

	float xT = pressure[coordT];
	float xB = pressure[coordB];
	float xR = pressure[coordR];
	float xL = pressure[coordL];
	float xU = pressure[coordU];
	float xD = pressure[coordD];

	// Sample divergence
	float bC = divergence[i];

	float final = (xL + xR + xB + xT + xU + xD - bC ) / 6;

	pressureResult[i] = final;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y, NUM_THREADS_Z)]
// enforce incompressibility condition by making the velocity divergence 0 by subtracting the pressure gradient
void SubtractGradientComputeShader( uint3 i : SV_DispatchThreadID ) {
	uint3 coordT = i + uint3(0, 1, 0);
	uint3 coordB = i - uint3(0, 1, 0);
	uint3 coordR = i + uint3(1, 0, 0);
	uint3 coordL = i - uint3(1, 0, 0);
	uint3 coordU = i + uint3(0, 0, 1);
	uint3 coordD = i - uint3(0, 0, 1);

	// Find neighbouring pressure
	float pT = pressure[coordT];
	float pB = pressure[coordB];
	float pR = pressure[coordR];
	float pL = pressure[coordL];
	float pU = pressure[coordU];
	float pD = pressure[coordD];
	float pC = pressure[i];

	// If an adjacent cell is solid or boundary, ignore its pressure and use its velocity. 
	if (coordT.y > vDimensions.y - 1) {
		pT = pC;
	}
	if (coordB.y < 1) {
		pB = pC;
	}
	if (coordR.x > vDimensions.x - 1) {
		pR = pC;
	}
	if (coordL.x < 1) {
		pL = pC;
	}
	if (coordU.z > vDimensions.z - 1) {
		pU = pC;
	}
	if (coordD.z < 1) {
		pD = pC;
	}

	// Compute the gradient of pressure at the current cell by taking central differences of neighboring pressure values. 
	float3 grad = float3(pR - pL, pT - pB, pU - pD) * 0.5f;
	// Project the velocity onto its divergence-free component by subtracting the gradient of pressure.  
	float3 oldV = velocity[i];
	float3 newV = oldV - grad;
	// Explicitly enforce the free-slip boundary condition by  
	// replacing the appropriate components of the new velocity with  
	// obstacle velocities. 
	velocityResult[i] = newV;
}

[numthreads(NUM_THREADS_X, NUM_THREADS_Y*2, 1)]
// Output the result of a 3D texture to a render target by using ray-marching
void RenderComputeShader( uint3 DTid : SV_DispatchThreadID ) {
	uint2 j = DTid.xy;

	float3 raydir = float3( (2*j - float2(vViewportDimensions)) / min(vViewportDimensions.x, vViewportDimensions.y) * fZoom , 0) - vEyePos;

	// rotate vuew
	float3 vEyeProper = mul(float4(vEyePos,1.0f), mRotationMatrix).xyz;
	raydir	   = mul(float4(raydir,1.0f), mRotationMatrix).xyz;

	float3 t1 = max((-1 - vEyeProper) / raydir, 0);
	float3 t2 = max(( 1 - vEyeProper) / raydir, 0);

	// Determine the closest and furthest points
	float3 front = min(t1, t2);
	float3 back  = max(t1, t2);

	float tfront = max(front.x, max(front.y, front.z));
	float tback  = min( back.x, min( back.y,  back.z));

	// Calculate texture coordinates of front and back intersection
	float3 texf  =  (vEyeProper + tfront*raydir + 1) * 0.5f;
	float3 texb  =  (vEyeProper + tback *raydir + 1) * 0.5f;

	// determine the number of steps necessary to traverse the simulation volume
	float steps = floor(length(texf - texb)*vDimensions.x + 0.5f);
	float3 texdir = (texb-texf)/steps;

	steps = (tfront >= tback) ? 0 : steps; // no intersection ?

	 // simple MIP render
	 float m = 0.0f;
	 for (float i = 0.5f; i < steps; ++i) {
		float3 samplingPoint = texf + i*texdir;
		float s = renderInputTexture.SampleLevel(linearSampler, samplingPoint, 0);      
		m += s;
		if (m > 1)
			break;
	 }

	 // hot metal color
	 float whiteSmoke = m*245.0f/250.0f;
	 float4 col = saturate(float4(whiteSmoke,whiteSmoke,whiteSmoke,m));
	 //float4 col = saturate(lerp(float4(0,-1.41,-3, -0.4), float4(1.41,1.41,1, 1.41), m/3));

	 renderResult[j] = col;
}