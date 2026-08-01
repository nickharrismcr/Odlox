#version 330

// Fragment shader with rainbow color effect based on incoming colors
in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;            // Time uniform for animation

out vec4 finalColor;

// Cheap single-pass box blur: (2*BLUR_RADIUS+1)^2 taps around fragTexCoord,
// texel size derived from the render texture's own resolution so it stays
// correct across window sizes without a resolution uniform from the Lox
// side. Bump BLUR_RADIUS for a stronger blur (cost grows with the square
// of the radius -- 1 is a 3x3/9-tap blur, 2 is 5x5/25-tap).
const int BLUR_RADIUS = 1;

vec4 blurredSample(sampler2D tex, vec2 uv) {
    vec2 texelSize = 1.0 / vec2(textureSize(tex, 0));
    vec4 sum = vec4(0.0);
    for (int x = -BLUR_RADIUS; x <= BLUR_RADIUS; x++) {
        for (int y = -BLUR_RADIUS; y <= BLUR_RADIUS; y++) {
            sum += texture(tex, uv + vec2(x, y) * texelSize);
        }
    }
    float taps = float((2 * BLUR_RADIUS + 1) * (2 * BLUR_RADIUS + 1));
    return sum / taps;
}

// Convert RGB to HSV
vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Convert HSV to RGB
vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main()
{
    // Sample the texture (blurred)
    vec4 texelColor = blurredSample(texture0, fragTexCoord);
    
    // Get base color from fragment and diffuse
    vec3 baseColor = fragColor.rgb * colDiffuse.rgb * texelColor.rgb;
    
    // Convert to HSV
    vec3 hsv = rgb2hsv(baseColor);
    
    // Shift the hue based on time, wrapping around [0,1]
    hsv.x = fract(hsv.x + time ); // Adjust speed with the multiplier
    
    // Convert back to RGB with shifted hue but original saturation and value
    vec3 shiftedColor = hsv2rgb(hsv);
    
    finalColor = vec4(shiftedColor, fragColor.a * colDiffuse.a * texelColor.a);
}
