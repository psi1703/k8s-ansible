from typing import List, Optional

from pydantic import BaseModel, Field


class WizardRecord(BaseModel):
    token: str
    display_name: str = ""
    iits_username: str = ""
    adm_username: str = ""
    completed: List[str] = Field(default_factory=list)
    adminCompleted: List[str] = Field(default_factory=list)
    iits_pw_date: Optional[str] = None
    adm_pw_date: Optional[str] = None
    vpn_date: Optional[str] = None
    test_env: str = ""
    prod_env: str = ""


class UserLoginPayload(BaseModel):
    token: str


class CredentialPayload(BaseModel):
    credential: str
    current: Optional[str] = None


class ConfigPayload(BaseModel):
    admin_tokens: List[str]
