#version 330

// Fragment shader for basic lighting with multiple light sources

// Input values from vertex shader
in vec3 fragPosition;
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;

// Input uniform values
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 lightPos[4];      // Up to 4 light positions
uniform vec4 lightColor[4];    // Up to 4 light colors
uniform float lightIntensity[4]; // Up to 4 light intensities
uniform int lightCount;        // Number of active lights
uniform vec3 viewPos;          // Camera position

// Output fragment color
out vec4 finalColor;

void main()
{
    // Material properties
    vec4 texelColor = texture(texture0, fragTexCoord);
    vec3 lightDot = vec3(0.0);
    vec3 normal = normalize(fragNormal);
    vec3 viewD = normalize(viewPos - fragPosition);
    vec3 specular = vec3(0.0);
    
    // Ambient light
    vec3 ambient = vec3(0.1, 0.1, 0.1);
    
    // Calculate lighting for each light source
    for (int i = 0; i < lightCount && i < 4; i+=1)
    {
        vec3 light = lightPos[i];
        vec3 lightDir = normalize(light - fragPosition);
        
        // Diffuse lighting
        float NdotL = max(dot(normal, lightDir), 0.0);
        lightDot += lightColor[i].rgb * NdotL * lightIntensity[i];
        
        // Specular lighting (Blinn-Phong)
        vec3 halfwayDir = normalize(lightDir + viewD);
        float spec = pow(max(dot(normal, halfwayDir), 0.0), 64.0);
        specular += lightColor[i].rgb * spec * lightIntensity[i] * 0.5;
    }
    
    // Final color calculation
    finalColor = (texelColor * ((colDiffuse + vec4(lightDot, 1.0)) + vec4(specular, 1.0))) * fragColor;
    finalColor += vec4(ambient, 0.0) * texelColor * fragColor;
    
    // Gamma correction
    finalColor = pow(finalColor, vec4(1.0/2.2));
}
