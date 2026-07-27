#version 330

// Vertex shader that calculates distance from origin for hue shifting
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;

uniform mat4 mvp;
uniform mat4 matModel;        // Model matrix to get world position

out vec2 fragTexCoord;
out vec4 fragColor;
out float distanceFromOrigin; // Pass distance to fragment shader

void main()
{
    // Transform vertex to world space
    vec4 worldPos = matModel * vec4(vertexPosition, 1.0);
    
    // Calculate distance from origin (0,0,0)
    distanceFromOrigin = length(worldPos.xyz);
    
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
