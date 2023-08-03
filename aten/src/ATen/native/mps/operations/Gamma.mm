#define TORCH_ASSERT_ONLY_METHOD_OPERATORS
#include <ATen/ExpandUtils.h>
#include <ATen/mps/MPSProfiler.h>
#include <ATen/native/Resize.h>
#include <ATen/native/mps/OperationUtils.h>
#include <fmt/format.h>

// #include <ATen/native/UnaryOps.h>
// #include <ATen/native/mps/UnaryConstants.h>
// #ifndef AT_PER_OPERATOR_HEADERS
// #include <ATen/Functions.h>
// #include <ATen/NativeFunctions.h>
// #else
#include <ATen/ops/lgamma_native.h>
// #endif


// namespace at::meta {
//   /* macro expands to: upsample_nearest1d::upsample_nearest1d( */
//   TORCH_META_FUNC(lgamma_out) (const Tensor& self) {
//     auto outputSize = self.sizes();

//     auto options = self.options().dtype(at::kFloat);

//     set_output(outputSize, options);
//   }
// }


namespace at::native {
namespace mps {

    const float PSI_10 = 2.25175258906672110764;

    kernel void digamma (device {0} *input [[buffer(0)]],
                        device {1} *output [[buffer(1)]],
                        uint id [[thread_position_in_grid]]) {
        if (x < 0) {
            if (x == trunc(x)) {
                // As per C++ standard for gamma related functions and SciPy,
                // If the argument is a negative integer, NaN is returned
                output[id] = NAN;
                }
            else {
                // Extracts the fractional part of x as r, since tan(pi * r) is more numerically
                // accurate than tan(pi * x). While these operations are mathematically equivalent
                // since both x and r are in radians and tan() has a periodicity of pi, in practice
                // the computation of pi * x is a source of error (when |x| > 1).
                float q, r;
                r = std::modf(x, &q);
                output[id] = calc_digamma_positive_domain(1 - x) - M_PI_BF / tan(M_PI_BF * r);
            }

  }

    }

    /*
 * This function is derived from the implementation of the digamma function in the Cephes Math Library.
 * See note [3-Clause BSD License for the Cephes Math Library].
 */
float calc_digamma_positive_domain(git x) {
  // [C++ Standard Reference: Gamma Function] https://en.cppreference.com/w/cpp/numeric/math/tgamma
  if (x == 0) {
    // As per C++ standard for gamma related functions and SciPy,
    // If the argument is ±0, ±∞ is returned
    return std::copysign(INFINITY, -x);
  }

  // Push x to be >= 10
  double result = 0;
  while (x < 10) {
    result -= 1 / x;
    x += 1;
  }
  if (x == 10) {
    return result + PSI_10;
  }

  // Compute asymptotic digamma
  static const double A[] = {
      8.33333333333333333333E-2,
      -2.10927960927960927961E-2,
      7.57575757575757575758E-3,
      -4.16666666666666666667E-3,
      3.96825396825396825397E-3,
      -8.33333333333333333333E-3,
      8.33333333333333333333E-2,
  };

  double y = 0;
  if (x < 1.0e17) {
    double z = 1.0 / (x * x);
    y = z * polevl(z, A, 6);
  }
  return result + log(x) - (0.5 / x) - y;
}

// The gamma function approximations come from John D Cook's
// c++ implementation:  https://www.johndcook.com/Gamma.cpp.

static const char* GAMMA_OPS_TEMPLATE = R"METAL(
#include <metal_stdlib>
using namespace metal;

constant float EULER_MASCHERONI = 0.577215664901532860606512090;

constant float HALF_LOG_TWO_PI = 0.91893853320467274178032973640562;

constant float LOG_PI = 1.14472988584940017414342735135305;

constant float PI = 3.141592653589793238462643383279502;


// numerator coefficients for approximation over the interval (1,2)
constant float GAMMA_NUMERATOR_COEF[8] =
    {{
        -1.71618513886549492533811E+0,
        2.47656508055759199108314E+1,
        -3.79804256470945635097577E+2,
        6.29331155312818442661052E+2,
        8.66966202790413211295064E+2,
        -3.14512729688483675254357E+4,
        -3.61444134186911729807069E+4,
        6.64561438202405440627855E+4
    }};

// denominator coefficients for approximation over the interval (1,2)
constant float GAMMA_DENOMINATOR_COEF[8] =
    {{
        -3.08402300119738975254353E+1,
        3.15350626979604161529144E+2,
        -1.01515636749021914166146E+3,
        -3.10777167157231109440444E+3,
        2.25381184209801510330112E+4,
        4.75584627752788110767815E+3,
        -1.34659959864969306392456E+5,
        -1.15132259675553483497211E+5
    }};

// lgamma expansion coefficients
constant float LGAMMA_EXPANSION_COEF[8] =
    {{
		 1.0/12.0,
		-1.0/360.0,
		1.0/1260.0,
		-1.0/1680.0,
		1.0/1188.0,
		-691.0/360360.0,
		1.0/156.0,
		-3617.0/122400.0
    }};

float LogGamma(float x);

float Gamma(float x) {{
    if (x < 0.001) {{
        // For small x, 1/Gamma(x) has power series x + gamma x^2  - ...
        // So in this range, 1/Gamma(x) = x + gamma x^2 with error on the order of x^3.
        // The relative error over this interval is less than 6e-7.

        return 1.0/(x*(1.0 + EULER_MASCHERONI * x));
    }}

	else if (x < 12.0) {{

        // The algorithm directly approximates gamma over (1,2) and uses
        // reduction identities to reduce other arguments to this interval.

		float y = x;
        int n = 0;
        bool less_than_one = (y < 1.0);

        // Add or subtract integers as necessary to bring y into (1,2)
        if (less_than_one)
        {{
            y += 1.0;
        }}
        else
        {{
            n = static_cast<int> (floor(y)) - 1;
            y -= n;
        }}

        float num = 0.0;
        float den = 1.0;
        int i;

        float z = y - 1;
        for (i = 0; i < 8; i++)
        {{
            num = (num + GAMMA_NUMERATOR_COEF[i])*z;
            den = den*z + GAMMA_DENOMINATOR_COEF[i];
        }}
        float result = num/den + 1.0;

        // Apply correction if argument was not initially in (1,2)
        if (less_than_one)
        {{
            // identity gamma(z) = gamma(z+1)/z
            result /= (y-1.0);
        }}
        else
        {{
            // identity gamma(z+n) = z*(z+1)* ... *(z+n-1)*gamma(z)
            for (i = 0; i < n; i++)
                result *= y++;
        }}

		return result;
    }}

    else {{
        return exp(LogGamma(x));
    }}
}}

float LogGamma(float x) {{

    float logGamma;

    bool is_negative = (x < 0);
    if (is_negative)
    {{
        x = -x;
    }}
    if (x == 0)
    {{
        return INFINITY;
    }}
    if (x < 12.0)
    {{
        logGamma = log(fabs(Gamma(x)));
    }}
    else
    {{
        // Abramowitz and Stegun 6.1.41
        // Asymptotic series should be good to at least 11 or 12 figures
        // For error analysis, see Whittiker and Watson
        // A Course in Modern Analysis (1927), page 252

        float z = 1.0 / (x*x);
        float sum = LGAMMA_EXPANSION_COEF[7];

        for (int i=6; i >= 0; i--)
        {{
            sum *= z;
            sum += LGAMMA_EXPANSION_COEF[i];
        }}
        float series = sum/x;

        logGamma = (x - 0.5) * log(x) - x + HALF_LOG_TWO_PI + series;
    }}

    if (is_negative)
    {{
        return LOG_PI - logGamma - log(fabs(x * sin(x * PI))); // Reflection Formula
    }}

    return logGamma;

}}


kernel void lgamma(device {0} *input [[buffer(0)]],
                   device {1} *output [[buffer(1)]],
                   uint id [[thread_position_in_grid]]) {{
    output[id] = LogGamma(static_cast<float>(input[id]));
}}

)METAL";

void dispatch1DJob(id<MTLComputeCommandEncoder> commandEncoder, id<MTLComputePipelineState> cplState, uint32_t length);

static id<MTLLibrary> compileGammaOpsLibrary(id<MTLDevice> device,
                                               const std::string& t1,
                                               const std::string& t2) {
  auto key = t1 + t2;
  static std::unordered_map<std::string, id<MTLLibrary>> libMap;
  auto it = libMap.find(key);
  if (it != libMap.end()) {
    return it->second;
  }
  NSError* error = nil;
  MTLCompileOptions* options = [[MTLCompileOptions new] autorelease];
  [options setLanguageVersion:MTLLanguageVersion2_3];
  auto rc =
      [device newLibraryWithSource:[NSString stringWithUTF8String:fmt::format(GAMMA_OPS_TEMPLATE, t1, t2).c_str()]
                           options:options
                             error:&error];
  TORCH_CHECK(rc != nil && error == nil, "Failed to compile library: ", [[error localizedDescription] UTF8String]);
  libMap[key] = rc;
  return rc;
}

id<MTLComputePipelineState> getCPLState(id<MTLDevice> device,
                                               const std::string& t1,
                                               const std::string& t2,
                                               const std::string& fname) {
  auto key = t1 + t2 + fname;
  static std::unordered_map<std::string, id<MTLComputePipelineState>> cplMap;
  auto it = cplMap.find(key);
  if (it != cplMap.end()) {
    return it->second;
  }
  NSError* error = nil;
  auto library = compileGammaOpsLibrary(device, t1, t2);
  id<MTLFunction> func = [library newFunctionWithName:[NSString stringWithUTF8String:fname.c_str()]];
  TORCH_CHECK(func != nil, "Can't get function ", fname);
  auto rc = [device newComputePipelineStateWithFunction:func error:&error];
  TORCH_CHECK(
      rc != nil && error == nil, "Failed to construct pipeline state: ", [[error localizedDescription] UTF8String]);
  cplMap[key] = rc;
  return rc;
}

} // namespace mps

TORCH_IMPL_FUNC(lgamma_out_mps)(const Tensor& self, const Tensor& output_) {

  TORCH_CHECK(self.scalar_type() != ScalarType::Double, "MPS does not support lgamma_out op with scalar type: Double");

  Tensor output = output_;
  bool needs_output_copy = false;
  uint32_t length = output.numel();
  if (length == 0) {
    return;
  }

  if (!self.is_contiguous()) {
      output = output.contiguous();
      needs_output_copy = true;
    }

  using namespace mps;

  std::string input_type = scalarToMetalTypeString(self.scalar_type());
  std::string output_type = scalarToMetalTypeString(output.scalar_type());

  @autoreleasepool {

    id<MTLDevice> device = MPSDevice::getInstance()->device();
    id<MTLComputePipelineState> cplState = getCPLState(device,
                                                        input_type,
                                                        output_type,
                                                        "lgamma");

    MPSStream* mpsStream = getCurrentMPSStream();
    dispatch_sync(mpsStream->queue(), ^() {
      id<MTLComputeCommandEncoder> computeEncoder = mpsStream->commandEncoder();
      id<MTLBuffer> outBuf = getMTLBufferStorage(output);
      id<MTLBuffer> selfBuf = getMTLBufferStorage(self);

      getMPSProfiler().beginProfileKernel(cplState, "lgamma_out", {self});

      [computeEncoder setComputePipelineState:cplState];
      [computeEncoder setBuffer:selfBuf offset:self.storage_offset() * self.element_size() atIndex:0];
      [computeEncoder setBuffer:outBuf offset:output.storage_offset() * output.element_size() atIndex:1];


      mps::dispatch1DJob(computeEncoder, cplState, static_cast<uint32_t>(length));

      getMPSProfiler().endProfileKernel(cplState);
    });
  }
  if (needs_output_copy) {
    output_.copy_(output);
  }
}

} // namespace at::native