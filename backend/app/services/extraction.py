import sys
from app.services.ingestion import extraction as _impl

class _ModuleFacade(sys.modules[__name__].__class__):
    def __getattr__(self, name):
        return getattr(_impl, name)
    def __setattr__(self, name, value):
        setattr(_impl, name, value)
        super().__setattr__(name, value)

sys.modules[__name__].__class__ = _ModuleFacade
globals().update({k: getattr(_impl, k) for k in dir(_impl)})
