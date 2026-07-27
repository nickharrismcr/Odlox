#version 330

// Fragment shader with time-based hue shifting for post-processing
in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;            // Time uniform for animation
uniform float hueScale;        // Scale factor for hue shift (default: 0.5)

out vec4 finalColor;

// HSV to RGB conversion
vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// RGB to HSV conversion
vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

void main()
{
    // Sample the texture from the frame buffer
    vec4 texelColor = texture(texture0, fragTexCoord);
    
    // Get base color
    vec3 baseColor = texelColor.rgb * colDiffuse.rgb;
    
    // Convert to HSV for hue manipulation
    vec3 hsv = rgb2hsv(baseColor);
    
    // Apply time-based hue shift
    float hueShiftScale = hueScale != 0.0 ? hueScale : 0.5;
    float hueShift = time * hueShiftScale;
    
    // Apply hue shift (wrap around at 1.0)
    hsv.x = fract(hsv.x + hueShift);
    
    // Convert back to RGB
    vec3 shiftedColor = hsv2rgb(hsv);
    
    // Preserve original alpha
    finalColor = vec4(shiftedColor, texelColor.a * colDiffuse.a);
}