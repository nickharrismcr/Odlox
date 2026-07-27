#version 330

// Fragment shader with pulsing intensity effect
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragPosition;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;
uniform vec3 center;           // Center position for pulse effect

out vec4 finalColor;

void main()
{
    // Calculate distance from center
    float dist = length(fragPosition - center);
    
    // Create pulsing intensity based on time and distance
    float pulse = 0.5 + 0.5 * sin(time * 3.0 - dist * 2.0);
    
    // Create energy rings
    float rings = sin(dist * 10.0 - time * 5.0) * 0.3 + 0.7;
    
    // Combine effects
    float intensity = pulse * rings;
    
    // Sample texture
    vec4 texelColor = texture(texture0, fragTexCoord);
    
    // Apply effects
    vec3 energyColor = vec3(0.2 + intensity * 0.8, 0.1 + intensity * 0.6, intensity);
    vec3 finalRGB = mix(fragColor.rgb * colDiffuse.rgb, energyColor, intensity * 0.4);
    
    finalColor = vec4(finalRGB * (0.8 + intensity * 0.4), fragColor.a * colDiffuse.a);
}
