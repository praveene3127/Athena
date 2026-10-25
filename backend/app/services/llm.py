import sys
from .marginalia import llm as _impl
globals().update({k: getattr(_impl, k) for k in dir(_impl)})
sys.modules[__name__] = _impl
