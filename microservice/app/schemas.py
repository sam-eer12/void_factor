"""The wire contract of an analysis, as the Flutter client reads it.

Declared as `response_model` on every provider route, so FastAPI validates what
leaves the service and publishes the shape in the OpenAPI schema. Anything
`normalize` produced that breaks these constraints is a bug in this service and
surfaces as a 500 here, rather than as a malformed entry in someone's food log.
"""
from pydantic import BaseModel, Field


class Nutrients(BaseModel):
    """One serving's macros. Always four finite, non-negative numbers."""

    calories: float = Field(ge=0, allow_inf_nan=False)
    protein_g: float = Field(ge=0, allow_inf_nan=False)
    carbs_g: float = Field(ge=0, allow_inf_nan=False)
    fats_g: float = Field(ge=0, allow_inf_nan=False)


class FoodAnalysis(BaseModel):
    # May be empty: a model that named nothing still measured something, and the
    # app's form makes the user name the entry before it is saved.
    name: str
    # How many of the serving [nutrients] describes are on the plate.
    quantity: float = Field(gt=0, allow_inf_nan=False)
    nutrients: Nutrients


class ErrorBody(BaseModel):
    """What every failure carries: FastAPI's `{"detail": ...}`.

    The prefix of `detail` is part of the contract — `auth:` for the caller's
    session, `image:` for the upload — because the client routes on it.
    """

    detail: str
