module "network" {
  source = "./modules/network"
  prefix = var.prefix
}

module "app-tier" {
  source = "./modules/app-tier"
  prefix = var.prefix
  vpc_id = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  app_subnet_ids = module.network.app_subnet_ids
  app_port = 3000
}